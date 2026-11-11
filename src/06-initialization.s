##
# Initialization
##

# board boot initializations
boot:
    # CH32V006 PORT BUGFIX: uart_print (called below for the boot banner) now
    # spills ra to the return stack, so RSP (s0) must be valid *before* the
    # first call to it -- reset: only initializes s0 later. Without this, the
    # banner-print stores through s0 == 0 (QingKe registers reset to zero),
    # faults, and the stub mret handler loops on the fault forever.
    li s0, RSP_TOP      # initialize RSP register early (reset: re-inits it, harmlessly)

    call interrupt_init # RISC-V interrupt CSR initialization
    call uart_init      # board specific UART initialization
    call gpio_init      # board specific GPIO initialization (a0 = skip button)

    # arm the boot replay unless the skip button (PD4 high) is held:
    # LOGSRC = -1 means "armed"; the first pass through reset: turns it into
    # LOG_BASE and the replay begins. Holding PD4 boots to a bare ok prompt,
    # the escape hatch for a log whose last line starts a broken main loop.
    # (CH32V006 PORT: gpio_init samples PD4 before PD5 becomes the UART TX)
    li t2, -1
    beqz a0, boot_arm
    mv t2, zero         # button held: no replay this boot
boot_arm:
    li t0, LOGSRC
    sw t2, 0(t0)

    # initialize HERE variable
    li t0, RAM_BASE     # load RAM_BASE memory address
    li t1, var_HERE     # load HERE variable
    sw t0, 0(t1)        # initialize HERE variable to contain RAM_BASE memory address

    # initialize LATEST variable
    la t0, last_word    # load address of the last word in Flash memory
                        # (CH32V006 PORT: was word_SEMI; last_word is set in
                        # sixforths.s after the last include, so it always
                        # follows the end of the chain)
    li t1, var_LATEST   # load LATEST variable
    sw t0, 0(t1)        # initialize LATEST variable to contain last_word memory address

    # CH32V006 PORT: source-replay log initialization
    call flash_unlock   # unlock the FPEC: program/erase enabled from here on
    call log_scan       # find the append frontier (first erased halfword)
    li t0, LOGEN
    sw zero, 0(t0)      # logging starts disabled (+log enables it)
    li t0, LOGPND
    sw zero, 0(t0)      # no pending batch

    # display boot message
    la a1, msg_boot     # load string message
    addi a2, a1, 16     # load string length
    call uart_print     # call uart print function
    j reset

# reset the Forth stack pointers, registers, variables, and state
reset:
    # CH32V006 PORT: replay arming. Boot arms LOGSRC with -1; this first
    # pass through reset starts the replay from LOG_BASE. Every later pass
    # through reset is an error path: abandon the replay (a bad log line can
    # never wedge the boot; the rest of the log is skipped and input falls
    # back to the UART) and drop the pending log batch (the failed line's
    # definition must not be logged).
    li t0, LOGSRC
    lw t1, 0(t0)
    li t2, -1
    bne t1, t2, reset_noreplay
    li t1, LOG_BASE
    sw t1, 0(t0)        # armed: begin the replay
    j reset_replay_done
reset_noreplay:
    sw zero, 0(t0)      # error or normal operation: input from the UART
reset_replay_done:
    li t0, LOGPND
    sw zero, 0(t0)      # drop any pending (uncommitted) log batch

    # initialize stack pointers
    la sp, __stacktop           # initialize DSP register
    la s1, interpreter_start    # initialize IP register
    li s0, RSP_TOP              # initialize RSP register

    # initialize function parameters
    mv a0, zero         # initialize W register
    mv a1, zero         # initialize X register
    mv a2, zero         # initialize Y register
    mv a3, zero         # initialize Z register

    # initialize STATE variable
    li t0, var_STATE    # load STATE variable
    sw zero, 0(t0)      # initialize STATE variable (0 = execute)

.balign CELL
# reset the RAM from the last defined word
ram_init:
    li t0, var_HERE     # load HERE memory address
    lw t0, 0(t0)        # load HERE value
    li t1, PAD          # load PAD variable
ram_zerofill:
    # initialize the memory cells
    beq t0, t1,ram_done # loop until counter (HERE) == PAD
    sw zero, 0(t0)      # zero-fill the memory address
    addi t0, t0, CELL   # increment counter by 1 CELL
    j ram_zerofill      # repeat
ram_done:
    # continue to tib_init

.balign CELL
# reset the terminal input buffer
tib_init:
    # initialize TOIN variable
    li t0, TIB_BOTTOM   # load TIB memory address
    li t1, var_TOIN     # load TOIN variable
    li t2, TIB_TOP      # load TIB_TOP variable
    sw zero, 0(t1)      # initialize TOIN variable to contain zero
tib_zerofill:
    # initialize the TIB
    beq t2, t0,tib_done # loop until TIB_TOP == TIB
    addi t2, t2, -CELL  # decrement TIB_TOP by 1 CELL
    sw zero, 0(t2)      # zero-fill the memory address
    j tib_zerofill      # repeat
tib_done:
    j interpreter_start # jump to the main interpreter REPL

msg_boot: .ascii "sixforths v0.0\n\n"
