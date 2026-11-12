##
# Internal functions
##

# convert a word header address to its code field address (jonesforth >CFA)
# The header is: link (1 CELL), flags+length byte, name bytes, zero padding
# to a CELL boundary, code field. So: cfa = align(header + CELL + 1 + len).
# arguments: a0 = word header address
# returns: a0 = code field address
# clobbers: t0
to_cfa:
    lbu t0, CELL(a0)    # load the flags+length byte
    andi t0, t0, F_LENMASK # keep only the name length
    add a0, a0, t0      # skip the name bytes
    addi a0, a0, 2*CELL # skip link + count byte + alignment slack (4 + 1 + 3)
    andi a0, a0, -CELL  # round down to the CELL boundary = the code field
    ret

# obtain a word (token) from the terminal input buffer
# arguments: a0 = buffer start address
# returns: a0 = token start address, a1 = token size (length in bytes)
token:
    li t1, CHAR_SPACE           # initialize temporary to 'space' character
    mv t2, zero                 # initialize temporary counter to 0
token_char:
    lbu t0, 0(a0)               # read char from buffer
    addi a0, a0, 1              # move buffer pointer up
    beqz t0, token_zero         # compare char with 0
    bgeu t1, t0, token_space    # compare char with space
    addi t2, t2, 1              # increment the token size for each non-space byte read
    j token_char                # loop to read the next character
token_space:
    beqz t2, token_char         # loop to read next character if token size is 0
    addi a0, a0, -1             # move buffer pointer down to ignore the space character
    sub a0, a0, t2              # store the start address in W
    j token_done
token_zero:
    addi a0, a0, -1             # move buffer pointer down to ignore the 0
token_done:
    mv a1, t2                   # store the size in X
    ret

# convert a string token to a 32-bit integer
# arguments: a0 = token buffer start address, a1 = token size (length in bytes)
# returns: a0 = integer value, a1 = 0 = OK, 1 or greater = ERROR
number:
    li t1, 10                   # initialize temporary to 10: number base (decimal)
    mv t0, zero                 # initialize temporary to 0: holds the final integer
    li a4, CHAR_MINUS           # initialize temporary to minus character '-'
    mv a5, zero                 # initialize temporary to 0: sign flag of integer
    lbu t2, 0(a0)               # load first character from W working register
    bne t2, a4, number_check    # jump to number check if the first character is not a minus sign

    # first character is a minus sign, so the number will be negative
    li a5, 1                    # number is negative, store a 1 flag in temporary
    addi a0, a0, 1              # increment buffer address by 1 character
    addi a1, a1, -1             # decrement the string length by 1
    beqz a1, number_error       # jump to error if the number is only a minus '-'
number_check:
    # CH32V006 PORT BUGFIX: upstream compared the first two characters with a
    # single lhu against 0x7830 ("0x", little-endian). Tokens sit at arbitrary
    # byte offsets inside the TIB, so that halfword load is misaligned
    # whenever a token starts at an odd address. The GD32V's Bumblebee core
    # performs misaligned halfword loads in hardware; the QingKe V2 traps
    # (mcause=4, observed on hardware at exactly this instruction, with the
    # symptom depending on token position parity in the line). Two byte
    # loads are alignment-immune and semantically identical.
    lbu t2, 0(a0)               # load the first character
    li a4, '0'
    bne t2, a4, number_digit    # not '0': jump to the number digit loop
    lbu t2, 1(a0)               # load the second character
    li a4, 'x'
    bne t2, a4, number_digit    # not 'x': jump to the number digit loop

    # first 2 characters are '0x', so let's assume the rest are hex digits
    li t1, 16                   # initialize temporary to 16: number base (hex)
    addi a0, a0, 2              # increment buffer address by 2 characters
    addi a1, a1, -2             # decrement the string length by 2
    beqz a1, number_error       # jump to error if the number is only '0x'
number_digit:
    beqz a1, number_done        # if the size of the buffer is 0 then we're done
    # CH32V006 PORT: the only `mul` in the kernel. It requires the Zmmul
    # extension (QingKe V2C has it; build with ARCH=rv32ec_zicsr_zmmul,
    # binutils >= 2.39). Shift-add fallback if your binutils is older
    # (a4 is dead at this point in the loop):
    #     slli a4, t0, 3          # n * 8
    #     slli t0, t0, 1          # n * 2
    #     add  t0, t0, a4         # n * 10   (decimal path)
    # (a branch on t1==16 doing `slli t0, t0, 4` would be needed for hex)
    mul t0, t0, t1              # multiply the number by the number base (10 or 16)
    lbu t2, 0(a0)               # load next character into temporary
    addi a0, a0, 1              # increment buffer address by 1 character

    # convert the character to a number
    sltiu a4, t2, 0x30          # set the result in a4 if the character is lower than '0'
    bnez a4, number_done        # we're done if it's not a digit!
    addi t2, t2, -0x30          # subtract '0' from the character
    sltiu a4, t2, 10            # set the result in a4 if the character is lower than 10
    bnez a4, number_number      # the character is a number (0-9)
    sltiu a4, t2, 0x41-0x30     # set the result in a4 if the character is lower than 17
    bnez a4, number_done        # we're done if it's not a letter!
    addi t2, t2, -7             # subtract 7 from the character to convert ascii to hex
number_number:
    slt a4, t2, t1              # set the result in a4 if it's lower than the base (10 or 16)
    beqz a4, number_done        # we're done if it's not a number (0-9) or (0-F)
    add t0, t0, t2              # add previous number to current digit
    addi a1, a1, -1             # decrement the string length by 1
    bnez a1, number_digit       # loop to check the next character if the length is > 0
number_done:
    beqz a5, number_store       # don't negate the number if it's positive
    neg t0, t0                  # negate the number using two's complement
number_store:
    # the value in a1 will be greater than 0 if it wasn't a valid number
    mv a0, t0                   # copy final number to W working register
    ret
number_error:
    li a1, 1                    # number is too large or not an integer, return 1
    ret

# search for a word in the dictionary by name (jonesforth FIND)
# arguments: a0 = token buffer address, a1 = token length, a2 = LATEST value
# returns: a1 = address of the word header if found (a0 is preserved)
# clobbers: t0, t1, t2, a2, a4, a5, gp
lookup:
    mv t2, a2                   # save the LATEST value for restorevars on error
lookup_loop:
    beqz a2, lookup_error       # error if the address is 0 (end of the dictionary)
    lbu t0, CELL(a2)            # load the flags+length byte of this word

    # check if the word is hidden
    andi t1, t0, F_HIDDEN       # read the hidden flag bit
    bnez t1, lookup_next        # skip the word if it's hidden

    # compare the lengths first (cheap reject)
    andi t0, t0, F_LENMASK      # keep only the name length
    bne t0, a1, lookup_next     # skip the word if the lengths differ

    # compare the name bytes
    addi a4, a2, CELL+1         # a4 = name pointer in the header
    mv a5, a0                   # a5 = token pointer (a0 itself is preserved)
    mv t1, t0                   # t1 = byte counter (length, always > 0)
lookup_cmp:
    beqz t1, lookup_done        # all bytes matched: found it
    lbu t0, 0(a4)               # load one name byte
    lbu gp, 0(a5)               # load one token byte
    bne t0, gp, lookup_next     # mismatch: try the previous word
    addi a4, a4, 1              # advance the name pointer
    addi a5, a5, 1              # advance the token pointer
    addi t1, t1, -1             # one byte down
    j lookup_cmp
lookup_next:
    lw a2, 0(a2)                # follow link to next word in dict
    j lookup_loop
lookup_error:
    # check the STATE
    li t0, var_STATE            # load the address of the STATE variable into temporary
    lw t0, 0(t0)                # load the current state into a temporary
    beqz t0, err_error          # if in execute mode (STATE = 0), jump to error handler to reset

    restorevars t2              # restore HERE and LATEST (t2)
    j err_error                 # jump to error handler
lookup_done:
    mv a1, a2                   # return the word header address in X
    ret

.balign CELL
# make_header: build a dictionary header at HERE
# arguments: a0 = name address, a1 = name length (1..31), a2 = code field
#            value, a3 = initial flags (0, or F_HIDDEN)
# leaves HERE just after the code field and LATEST pointing at the new word.
# Same layout and bounds check as ':' in 08-forth-primitives.s.
# HERE is rounded up to a CELL boundary first, so a header can follow `c,`.
# clobbers: t0, t1, t2, a0, a4, a5, gp, tp
make_header:
    li t0, var_HERE
    lw t2, 0(t0)
    addi t2, t2, CELL-1         # HERE may be unaligned after `c,` or `allot`
    andi t2, t2, -CELL          # t2 = address of the new header (aligned)
    add a5, t2, a1              # header + name length...
    addi a5, a5, 2*CELL         # ...+ link + count byte + alignment slack
    andi a5, a5, -CELL          # a5 = code field address
    addi gp, a5, CELL           # gp = new HERE
    li tp, LOGBUF-CELL          # keep one spare cell: CREATE reserves it for DOES>
    bge gp, tp, err_mem         # dictionary full
    li t1, var_LATEST
    lw a4, 0(t1)
    sw a4, 0(t2)                # link field = previous LATEST
    or a4, a1, a3               # flags + length byte
    sb a4, CELL(t2)
    addi a4, t2, CELL+1         # a4 = name destination
    mv t1, a1                   # t1 = byte counter
mkh_copy:
    lbu t0, 0(a0)
    sb t0, 0(a4)
    addi a0, a0, 1
    addi a4, a4, 1
    addi t1, t1, -1
    bnez t1, mkh_copy
mkh_pad:
    beq a4, a5, mkh_code        # zero the padding: headers must be deterministic
    sb zero, 0(a4)
    addi a4, a4, 1
    j mkh_pad
mkh_code:
    sw a2, 0(a5)                # code field
    li t1, var_LATEST
    sw t2, 0(t1)                # LATEST = the new word
    li t0, var_HERE
    sw gp, 0(t0)                # HERE = just after the code field
    ret
