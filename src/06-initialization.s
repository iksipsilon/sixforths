##
# Initialization
##

message boot, "sixforths v0.0\n\n"

.balign CELL
# board boot initializations
boot:
    # CH32V006 PORT: the machine stack first, for interrupt frames (HPE) and
    # the return addresses of nested subroutines (uart_print, called below
    # for the banner, keeps ra there). Interrupts are off after a hardware
    # reset; after `reboot` sp is still valid from before.
    li t0, MSP_TOP
    mv sp, t0

    call interrupt_init # RISC-V interrupt CSR initialization
    call uart_init      # board specific UART initialization
    call ticks_init     # CH32V006 PORT: start SysTick for ticks and ms (13-ticks.s)
    call gpio_init      # board specific GPIO initialization (a0 = skip button)

    # CH32V006 PORT: line 0 is interpreted first, unless the skip button
    # (PD4 high) is held. Holding PD4 boots to a bare ok prompt, the escape
    # hatch for a line 0 that starts a broken main loop.
    # (gpio_init samples PD4 with PD5 driven low)
    li t0, var_SRC
    sw zero, 0(t0)      # input from the UART
    bnez a0, boot_noload
    li t1, LINES_BASE
    sw t1, 0(t0)        # button released: input from line 0...
    addi t1, t1, LINE_SIZE
    sw t1, var_SRCEND-var_SRC(t0) # ...and from that line only
boot_noload:

    call modem_init     # CH32V006 PORT: USART2 + DMA ring for mkey and memit (14-modem.s)

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

    # CH32V006 PORT: one vocabulary to begin with, FORTH, whose head cell is
    # the LATEST variable (reset: points CONTEXT and CURRENT back at it)
    li t0, var_CURRENT
    sw t1, 0(t0)        # definitions go to FORTH (t1 = var_LATEST)
    li t0, var_VOCLINK
    sw zero, 0(t0)      # no other vocabulary exists yet

    # CH32V006 PORT: numbers print in decimal until `hex` says otherwise
    li t0, 10
    li t1, var_BASE
    sw t0, 0(t1)

    # CH32V006 PORT: unlock the FPEC: program/erase enabled from here on
    call flash_unlock

    # display boot message
    print_message boot
    j reset_boot        # not through reset: it would abandon line 0

# reset the Forth stack pointers, registers, variables, and state
reset:
    # CH32V006 PORT: an error abandons the lines being loaded (a bad line can
    # never wedge the boot): input falls back to the UART.
    li t0, var_SRC
    sw zero, 0(t0)
reset_boot:
    # initialize stack pointers
    # CH32V006 PORT: the machine stack is emptied too: an error may have left
    # a subroutine's return address on it. sp gets its value in one
    # instruction (mv), so a tick always finds a whole sp.
    li t0, MSP_TOP
    mv sp, t0
    li s0, DSP_TOP              # initialize DSP register
    # CH32V006 PORT: interrupts on (the tick, 13-ticks.s).
    # At boot this is the first time; after an error they are on already.
    csrs mstatus, 0x08
    la s1, interpreter_start    # initialize IP register
    li tp, RSP_TOP              # initialize RSP register

    # initialize function parameters
    mv a0, zero         # initialize W register
    mv a1, zero         # initialize X register
    mv a2, zero         # initialize Y register
    mv a3, zero         # initialize Z register

    # initialize STATE variable
    li t0, var_STATE    # load STATE variable
    sw zero, 0(t0)      # initialize STATE variable (0 = execute)

    # CH32V006 PORT: an error may have interrupted a colon definition
    call abandon_def    # drop it (a no-op on the first pass and after `;`)

    # CH32V006 PORT: after an error (and at boot) the search order and the
    # definitions are back in FORTH, as in fig-Forth's ABORT. An error in the
    # middle of `edit definitions ...` must not leave later words in edit.
    li t0, var_LATEST
    li t1, var_CONTEXT
    sw t0, 0(t1)
    li t1, var_CURRENT
    sw t0, 0(t1)

    # CH32V006 PORT: and output and input are the console's again (>console
    # <console), so the REPL is never left talking to the modem
    li t0, var_OUT
    la t1, uart_put
    sw t1, 0(t0)
    li t0, var_IN
    la t1, in_console
    sw t1, 0(t0)

.balign CELL
# reset the RAM from the last defined word
ram_init:
    li t0, var_HERE     # load HERE memory address
    lw t0, 0(t0)        # load HERE value
    # CH32V006 PORT BUGFIX: `c,` and `allot` may leave HERE unaligned. The
    # sw below would then trap (and the loop could never hit the end exactly),
    # so any error typed after e.g. `3 allot` hung the board in the trap
    # handler. Start the fill at the next CELL boundary.
    addi t0, t0, CELL-1
    andi t0, t0, -CELL
    # CH32V006 PORT: fill only the free dictionary, up to DICT_TOP (it was PAD).
    # The buffers above it must survive an error: the DMA keeps writing modem
    # bytes into MRING, and those not yet read would be lost. Stop at or above
    # the end: with `beq`, a HERE above DICT_TOP would run the fill off the end
    # of RAM.
    li t1, DICT_TOP     # load the top of the dictionary
ram_zerofill:
    # initialize the memory cells
    bgeu t0, t1, ram_done # loop until counter (HERE) reaches DICT_TOP
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

