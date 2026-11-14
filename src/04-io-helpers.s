##
# I/O Helpers
##

uart_get:
    # CH32V006 PORT: input source switch for the source-replay log. When
    # LOGSRC is nonzero it points into the flash log, and bytes come from
    # there instead of the USART; the interpreter cannot tell the
    # difference (replayed source even echoes, so the boot transcript shows
    # exactly what was replayed). The first 0xFF byte (erased flash) or the
    # end of the region switches the source back to the UART permanently.
    # If the log does not end with a newline (a partially-written last line,
    # e.g. power loss mid-append), one final newline is injected so it can
    # never leave the TIB half-filled; otherwise nothing is injected, so the
    # replay leaves no extra empty line and "ok" behind.
    # Clobbers only t0/t1 beyond the original code: interpreter loop state
    # (t2 = TIB, a1 = TOIN pointer, a4) stays intact across calls.
    li t0, LOGSRC
    lw t1, 0(t0)
    beqz t1, uart_get_hw        # 0: normal UART input
    li a0, LOG_TOP
    bgeu t1, a0, uart_get_end   # ran off the end of the log region
    lbu a0, 0(t1)               # read one byte of replayed source
    xori a0, a0, 0xFF           # a0 = 0 iff the byte is 0xFF (erased)
    beqz a0, uart_get_end       # erased flash: end of the log
    xori a0, a0, 0xFF           # restore the byte
    addi t1, t1, 1
    sw t1, 0(t0)                # advance the replay pointer
    ret
uart_get_end:
    # t1 = first address not replayed (the end marker, or LOG_TOP)
    sw zero, 0(t0)              # replay done: all input from the UART now
    li a0, LOG_BASE
    beq t1, a0, uart_get_hw     # empty log: nothing to close
    lbu a0, -1(t1)              # the last replayed byte
    li t1, CHAR_NEWLINE
    beq a0, t1, uart_get_hw     # the log ends with a whole line: on to the UART
    li a0, CHAR_NEWLINE         # partial last line: close it
    ret
uart_get_hw:
    li t0, UART_BASE_ADDRESS  # load UART base address (CH32V006 PORT: USART1, defined in mcu.s)
uart_get_loop:
    lw t1, UART_RX_STATUS(t0)   # load value from status register
    andi t1, t1, UART_RX_BIT    # load read data buffer not empty bit
    beqz t1, uart_get_loop      # loop until ready to receive
    lbu a0, UART_RX_DATA(t0)    # read character (zero-extended) from data register

    ret

uart_put:
    li t0, UART_BASE_ADDRESS  # load UART base address (CH32V006 PORT: USART1, defined in mcu.s)
uart_put_loop:
    lw t1, UART_TX_STATUS(t0)   # load value from status register
    andi t1, t1, UART_TX_BIT    # load transmit data buffer empty bit
    beqz t1, uart_put_loop      # loop until ready to send
    sb a0, UART_TX_DATA(t0)     # send character to data register

    ret

# print a string to the uart
# arguments: a1 = address of the message to be printed, a2 = address+length of the message
uart_print:
    # CH32V006 PORT: s3 does not exist on RV32E. Instead of holding ra in a
    # register across the nested call, it goes on the machine stack. Not on
    # Forth's return stack: the error messages are printed with this routine,
    # and after an error the RSP may hold anything.
    addi sp, sp, -CELL
    sw ra, 0(sp)                # save the return address
uart_print_loop:
    beq a1, a2, uart_print_done # done if we've printed all characters
    lbu a0, 0(a1)               # load 1 character from the message string
    call uart_put
    addi a1, a1, 1              # increment the address by 1
    j uart_print_loop           # loop to print the next message
uart_print_done:
    lw ra, 0(sp)                # restore the return address
    addi sp, sp, CELL
    ret

##
# CH32V006 PORT: vectored output and input (var_OUT, var_IN in
# 01-variables-constants.s). uart_put / uart_print / uart_get above stay the
# console's own routines: the REPL and the error messages use them directly.
##

# send a0 through the output vector (console, modem, ...)
# clobbers: t0, t1 (every output routine keeps to those, like uart_put)
out_put:
    li t0, var_OUT
    lw t0, 0(t0)
    jr t0                       # the routine returns straight to our caller

# print a string through the output vector, like uart_print does to the console
# arguments: a1 = start, a2 = end; clobbers: a0, a1, t0, t1
out_print:
    addi sp, sp, -CELL          # ra goes on the machine stack, as in
    sw ra, 0(sp)                # uart_print
out_print_loop:
    beq a1, a2, out_print_done
    lbu a0, 0(a1)
    call out_put
    addi a1, a1, 1
    j out_print_loop
out_print_done:
    lw ra, 0(sp)
    addi sp, sp, CELL
    ret

# is a console character waiting? a0 = -1 if one is, else 0. clobbers t0, t1
console_ready:
    li t0, UART_BASE_ADDRESS
    lw t1, UART_RX_STATUS(t0)
    andi t1, t1, UART_RX_BIT
    snez a0, t1
    neg a0, a0
    ret

# the console as an input source for var_IN: get (uart_get, which serves the
# boot replay from the log too), ready
.balign CELL
in_console:
    .word uart_get, console_ready
