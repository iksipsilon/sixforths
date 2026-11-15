##
# Interpreter
##

# here's where the program starts (the interpreter)
interpreter_start:
    li t2, TIB_BOTTOM                           # load TIB memory address
    li a4, var_TOIN                             # load the TOIN variable into unused temporary register
    lw a1, 0(a4)                                # load TOIN value into X working register
    add a1, a1, t2                              # add TIB to TOIN to get the start address of TOIN

interpreter:
    call uart_get                               # read a character from UART
    li a5, CHAR_NEWLINE                         # load newline into temporary
    bne a0, a5, interpreter_char                # not a newline: filter and echo it below
    # Echo the newline too, so the line's output (and "ok") starts on the
    # next line instead of right after the input
    call uart_put                               # send the newline to UART
    j skip_send

interpreter_char:
    # ignore specific characters
    beqz a0, interpreter                        # ignore the character if it matches
    li a5, CHAR_CARRIAGE                        # load 0x0D carriage return into temporary
    beq a0, a5, interpreter                     # ignore the character if it matches

    # Swallow ANSI terminal escape sequences (arrow keys, Delete key,
    # F-keys...) so they do not pollute the TIB as token bytes.
    # ESC [ ... <final 0x40-0x7E> is a CSI sequence; ESC O <byte> is SS3.
    li a5, 0x1B                                 # ESC
    beq a0, a5, skip_escape

    # Handle erase characters BEFORE echoing, so the erase sequence renders
    # correctly, and accept DEL (0x7F) in addition to BS (0x08): most
    # terminals (and picocom by default) send DEL for the backspace key.
    li a5, CHAR_BACKSPACE                       # 0x08
    beq a0, a5, process_backspace
    li a5, 0x7F                                 # DEL
    beq a0, a5, process_backspace

    call uart_put                               # send the character to UART

skip_send:
    # validate the character which is located in the W (a0) register
    li t0, CHAR_COMMENT                         # load comment character into temporary
    beq a0, t0, skip_comment                    # skip the comment if it matches

    li t0, CHAR_COMMENT_OPARENS                 # load opening parens into temporary
    beq a0, t0, skip_oparens                    # skip the opening parens if it matches

    # add the character to the TIB. Its last byte is never written: it stays
    # 0 (tib_init), the end mark `token` stops at. So a line holds at most
    # TIB_SIZE-2 characters and the newline.
store_char:
    li a5, TIB_TOP-1                            # load the address of the TIB's last byte
    bge a1, a5, err_tib                         # error if the terminal input buffer is full
    sb a0, 0(a1)                                # store the character from W register in the TIB
    addi a1, a1, 1                              # increment TOIN value by 1
    li t0, CHAR_NEWLINE                         # load newline into temporary
    beq a0, t0, replace_newline                 # process the token if it matches

    j interpreter                               # return to the interpreter if it's not a newline

# The comments are echoed but never reach the TIB. The newline that ends one
# does: it ends the line like any other, so what stands before the comment is
# interpreted now, and a line that is only a comment gets its ok.
skip_comment:
    checkchar CHAR_NEWLINE, store_char          # check if character is a newline
    j skip_comment                              # loop until it's a newline

# A ( comment ends at ) or at the end of its line, whichever comes first: an
# unclosed ( must not swallow the lines after it.
skip_oparens:
    checkchar CHAR_COMMENT_CPARENS, interpreter # check if character is a closing parens
    li t0, CHAR_NEWLINE
    beq a0, t0, store_char                      # the end of the line ends it too
    j skip_oparens                              # loop until it's a closing parens

skip_escape:
    call uart_get           # read the byte after ESC
    li a5, '['
    beq a0, a5, skip_csi    # CSI sequence: consume until its final byte
    li a5, 'O'
    beq a0, a5, skip_ss3    # SS3 sequence (F1-F4): one more byte follows
    j interpreter           # lone ESC + other byte: swallow and continue
skip_csi:
    call uart_get           # consume parameter/intermediate bytes...
    li a5, 0x40
    blt a0, a5, skip_csi    # ...until the final byte, which is 0x40-0x7E
    li a5, 0x7E
    bgt a0, a5, skip_csi
    j interpreter
skip_ss3:
    call uart_get           # consume the single SS3 final byte
    j interpreter

process_backspace:
    # Nothing was echoed for the erase key (see above), so if the TIB is
    # empty there is nothing to do at all; otherwise remove the last buffered
    # character and erase it on screen with BS, space, BS. The character is
    # cleared in the TIB too: the newline will overwrite only one byte, and
    # whatever else lay after the line would be parsed as part of it.
    beq a1, t2, interpreter # nothing to erase if TOIN == TIB
    addi a1, a1, -1         # remove the last character from the TIB
    sb zero, 0(a1)          # and clear it: what follows the line stays 0
    li a0, '\b'
    call uart_put           # move the cursor left...
    li a0, ' '
    call uart_put           # ...blank the character...
    li a0, '\b'
    call uart_put           # ...and move left again
    j interpreter

replace_newline:
    li a0, CHAR_SPACE       # convert newline to a space
    sb a0, -1(a1)           # replace previous newline character with space in W register

process_token:
    # process the token
    call token              # read the token and move TOIN past it

    # bounds checks on token size
    beqz a1, err_ok         # ok if token size is 0
    li t0, F_LENMASK        # load max token size (31: 5 length bits) in temporary
    bgtu a1, t0, err_token  # error if token size is greater than 31

    # check if the token is a number
    mv a2, a0               # save a0 temporarily (number leaves a2 and a3 alone)
    mv a3, a1               # save a1 temporarily
    call number             # try to convert the token to an integer
    beqz a1, push_number    # push the token to the stack or memory if it's a number
    mv a0, a2               # restore a0
    mv a1, a3               # restore a1

    # look the token up by name (a0 = address, a1 = length)
    call lookup             # search the context vocabulary, then FORTH;
                            # a1 = word header address

    # check if the word is immediate
    lbu t0, CELL(a1)        # load the flags+length byte of the found word
    andi t0, t0, F_IMMEDIATE # read the status of the immediate flag bit

    # load the STATE variable value
    li t1, var_STATE        # load the address of the STATE variable into temporary
    lw t1, 0(t1)            # load the current state into a temporary

    # decide if we want to execute or compile the word
    or t0, t0, t1           # logical OR the immediate flag and state
    addi t0, t0, -1         # decrement the result by 1
    beqz t0, compile        # compile the word if the result is 0
                            # otherwise fall through and execute it

execute:
    la s1, .loop            # load the address of the interpreter into the IP register
    mv a0, a1               # copy the word header address into W
    call to_cfa             # compute the code field address (variable-length names)
    lw t0, 0(a0)            # load memory address from W into temporary
    jr t0                   # jump to the address in temporary

# These two data words are read with lw through the IP register (NEXT does
# `lw a0, 0(s1)` with s1 pointing here). With compressed instructions the
# code before them can end on any 2-byte boundary, and a misaligned lw traps
# on the QingKe V2 (mcause = 4), hence the .balign.
.balign CELL
.loop: .word .dloop         # double indirect jump to interpreter
.dloop: .word process_token # indirect jump to interpreter after executing a word

compile:
    mv a0, a1               # copy the word header address into W
    call to_cfa             # compute the code field address (variable-length names)
    call comma              # append it to the current definition (05-internal-functions.s:
                            # a full dictionary or an unaligned HERE is an error)
    j process_token

push_number:
    # push to stack if STATE = 0 (execute)
    li t1, var_STATE        # load the address of the STATE variable into temporary
    lw t1, 0(t1)            # load the current state into a temporary
    beqz t1, push_stack     # if in execute mode, push the number to the stack
    # compile it as a literal if STATE = 1 (compile), like [']
    mv a1, a0               # keep the number (comma leaves a1 alone)
    la a0, LIT              # load the codeword address of LIT
    call comma              # append the LIT cell...
    mv a0, a1
    call comma              # ...then the number
    j process_token         # jump back to process the next token
push_stack:
    PUSH a0                 # push the W working register to the top of the data stack
    j process_token         # jump back to process the next token
