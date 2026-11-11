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
    # register across the nested call, spill it to the Forth return stack.
    # Deliberately NOT using the PUSHRSP/POPRSP macros here: their bounds check
    # jumps to err_overflow, which prints via uart_print -> infinite recursion
    # if the RSP were ever exhausted. uart_print nests exactly one cell deep,
    # so an unchecked push is safe (and clobbers no temporaries).
    addi s0, s0, -CELL          # make room on the return stack (RSP)
    sw ra, 0(s0)                # save the return address on the return stack
uart_print_loop:
    beq a1, a2, uart_print_done # done if we've printed all characters
    lbu a0, 0(a1)               # load 1 character from the message string
    call uart_put
    addi a1, a1, 1              # increment the address by 1
    j uart_print_loop           # loop to print the next message
uart_print_done:
    lw ra, 0(s0)                # CH32V006 PORT: restore the return address from the RSP
    addi s0, s0, CELL           # drop it from the return stack
    ret
