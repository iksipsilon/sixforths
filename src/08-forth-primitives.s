##
# Forth primitives
##

# reboot ( -- )         # Reboot the entire system and initialize memory
defcode "reboot",6,,REBOOT
    j err_reboot        # jump to reboot

# @ ( addr -- x )       Fetch memory at addr
defcode "@",1,,FETCH
    checkunderflow 0    # check for stack underflow of data stack (1 CELL)
    lw t0, 0(sp)        # load the top of stack into temporary
    lw t0, 0(t0)        # load the value from the temporary (addr)
    sw t0, 0(sp)        # store the value back the top of stack (x)
    NEXT

# ! ( x addr -- )       Store x at addr
defcode "!",1,,STORE
    checkunderflow CELL # check for stack underflow of data stack (2 CELLs)
    lw t1, 0(sp)        # load the DSP value (addr) into temporary
    lw t0, CELL(sp)     # load the DSP value (x) into temporary
    sw t0, 0(t1)        # store x into addr
    addi sp, sp, 2*CELL # move DSP up by 2 cells
    NEXT

# sp@ ( -- addr )       Get current data stack pointer (the address of the
# top cell before sp@ pushed its result)
defcode "sp@",3,,DSPFETCH
    mv t1, sp           # PUSH moves the DSP before it stores
    PUSH t1             # store DSP in the top of the stack
    NEXT

# rp@ ( -- addr )       Get current return stack pointer
defcode "rp@",3,,RSPFETCH
    PUSH s0             # store RSP in the top of the stack
    NEXT

# 0= ( x -- f )         -1 if top of stack is 0, 0 otherwise
defcode "0=",2,,ZEQU
    checkunderflow 0    # check for stack underflow of data stack (1 CELL)
    lw t0, 0(sp)        # load the DSP value (x) into temporary
    snez t0, t0         # store 0 in temporary if it's equal to 0, otherwise store 1
    addi t0, t0, -1     # store -1 in temporary if it's 0, otherwise store 0
    sw t0, 0(sp)        # store value back into the top of the stack
    NEXT

# + ( x1 x2 -- n )      Add the two values at the top of the stack
defcode "+",1,,ADD
    checkunderflow CELL # check for stack underflow of data stack (2 CELLs)
    POP t0              # pop DSP value (x1) into temporary
    lw t1, 0(sp)        # load DSP value (x2) into temporary
    add t0, t0, t1      # add the two values
    sw t0, 0(sp)        # store the value into the top of the stack
    NEXT

# nand ( x1 x2 -- n )   Bitwise NAND the two values at the top of the stack
defcode "nand",4,,NAND
    checkunderflow CELL # check for stack underflow of data stack (2 CELLs)
    POP t0              # pop DSP value (x1) into temporary
    lw t1, 0(sp)        # load DSP value (x2) into temporary
    and t0, t0, t1      # perform bitwise AND of the two values
    not t0, t0          # perform bitwise NOT of the value
    sw t0, 0(sp)        # store the value into the top of the stack
    NEXT

# lit ( -- n )          Get the next word from IP and push it to the stack, increment IP
defcode "lit",3,,LIT
    lw t1, 0(s1)        # load the memory address from IP into temporary
    PUSH t1             # push the literal to the top of the stack
    addi s1, s1, CELL   # increment IP by 1 CELL
    NEXT

# exit ( r:addr -- )    Resume execution at address at the top of the return stack
defcode "exit",4,,EXIT
    POPRSP s1           # pop RSP into IP
    NEXT

##
# Forth I/O
##

# key ( -- x )          Read 8-bit character from uart input
defcode "key",3,,KEY
    call uart_get       # read character from uart into W
    PUSH a0             # store character into top of data stack
    NEXT

# emit ( x -- )         Write 8-bit character to uart output
defcode "emit",4,,EMIT
    checkunderflow 0    # check for stack underflow of data stack (1 CELL)
    POP a0              # copy top of data stack into W
    call uart_put       # send character from W to uart
    NEXT

##
# Forth variables
##

# tib ( -- addr )       Store TIB variable address in top of data stack
defcode "tib",3,,TIB
    li t1, TIB_BOTTOM   # load variable into temporary
    PUSH t1
    NEXT

# state ( -- addr )     Store STATE variable address in top of data stack
defcode "state",5,,STATE
    li t1, var_STATE    # load variable into temporary
    PUSH t1
    NEXT

# >in ( -- addr )       Store TOIN variable address in top of data stack
defcode ">in",3,,TOIN
    li t1, var_TOIN     # load variable into temporary
    PUSH t1
    NEXT

# here ( -- addr )      Store HERE variable address in top of data stack
defcode "here",4,,HERE
    li t1, var_HERE     # load variable into temporary
    PUSH t1
    NEXT

# latest ( -- addr )     Store LATEST variable address in top of data stack
defcode "latest",6,,LATEST
    li t1, var_LATEST   # load variable into temporary
    PUSH t1
    NEXT

##
# Forth words
##

# : ( -- )              # Start the definition of a new word
defcode ":",1,,COLON
    li t2, TIB_BOTTOM   # load TIB memory address
    li a4, var_TOIN     # load TOIN variable into unused temporary register
    lw a0, 0(a4)        # load TOIN value into temporary
    add a0, a0, t2      # add TIB to TOIN to get the start address of TOIN
    call token          # read the token

    # move TOIN
    li t2, TIB_BOTTOM   # load TIB memory address
    add t0, a0, a1      # add the size of the token to TOIN
    sub t0, t0, t2      # subtract the address of TOIN from TIB to get the new size of TOIN
    sw t0, 0(a4)        # move TOIN to process the next word in the TIB

    # bounds checks on token size
    beqz a1, err_ok     # ok if token size is 0
    li t0, F_LENMASK    # load max token size (31: 5 length bits) in temporary
    bgtu a1, t0, err_token # error if token size is greater than 31

    # CH32V006 PORT: build a jonesforth-style header instead of a hashed one:
    # link cell, flags+length byte (HIDDEN while compiling), the name itself,
    # zero padding to the next CELL boundary, then the code field.
    li t0, var_HERE
    lw t2, 0(t0)        # t2 = HERE value...
    addi t2, t2, CELL-1 # ...rounded up to a CELL boundary (after `c,` or an
    andi t2, t2, -CELL  # odd `allot`) = address of the new word header

    # compute the code field address and the new HERE; bounds check first
    add a5, t2, a1      # header + name length...
    addi a5, a5, 2*CELL # ...+ link + count byte + alignment slack (4 + 1 + 3)
    andi a5, a5, -CELL  # a5 = code field address (CELL-aligned)
    addi gp, a5, CELL   # gp = new HERE (just after the code field)
    li tp, LOGBUF       # load out of bounds memory address (LOGBUF)
    bge gp, tp, err_mem # error if the memory address is out of bounds

    # link field: address of the previous word
    li t1, var_LATEST
    lw a4, 0(t1)        # load the address of the previous word (LATEST)
    sw a4, 0(t2)        # store it in the link field

    # flags+length byte: hide the word while it is being compiled
    ori a4, a1, F_HIDDEN
    sb a4, CELL(t2)     # store the flags+length byte after the link

    # copy the name bytes from the TIB into the header
    addi a4, t2, CELL+1 # a4 = destination: name area in the header
    mv t1, a1           # t1 = byte counter (token length, always > 0 here)
colon_copy:
    lbu t0, 0(a0)       # load one name byte from the token
    sb t0, 0(a4)        # store it in the header
    addi a0, a0, 1      # advance the source pointer
    addi a4, a4, 1      # advance the destination pointer
    addi t1, t1, -1     # one byte down
    bnez t1, colon_copy # loop until the whole name is copied

    # zero the padding between the name and the code field (deterministic
    # headers: required once these are written to flash verbatim)
colon_pad:
    beq a4, a5, colon_code # done when the pad pointer reaches the code field
    sb zero, 0(a4)      # zero one padding byte
    addi a4, a4, 1      # advance the pad pointer
    j colon_pad
colon_code:
    # code field: points at the machine code that jumps to docol
    la a2, .addr        # load the codeword address into Y working register
    sw a2, 0(a5)        # store the codeword address into the code field

    # update LATEST variable
    li t1, var_LATEST
    sw t2, 0(t1)        # store the new word address into the LATEST variable

    # update HERE variable
    li t0, var_HERE
    sw gp, 0(t0)        # store the new address of HERE into the HERE variable

    # update STATE variable
    li t0, var_STATE    # load the address of the STATE variable into temporary
    li t1, 1            # set the STATE variable to compile mode (1 = compile)
    sw t1, 0(t0)        # store the current state back into the STATE variable
    NEXT

docol:
    PUSHRSP s1          # push IP onto the return stack
    addi s1, a0, CELL   # skip code field in W by adding 1 CELL, store it in IP
    NEXT

.addr:
    j docol             # indirect jump to interpreter after executing a word

# ; ( -- )              # End the definition of a new word
defcode ";",1,F_IMMEDIATE,SEMI
    # unhide the word
    li t0, var_LATEST   # copy the memory address of LATEST into temporary
    lw t0, 0(t0)        # load the address value into temporary
    lbu t1, CELL(t0)    # load the flags+length byte into temporary
    andi t1, t1, ~F_HIDDEN # unhide the word
    sb t1, CELL(t0)     # write the flags+length byte back to memory

    # store codeword into memory
    li t0, var_HERE     # copy the memory address of HERE into temporary
    lw t2, 0(t0)        # load the HERE value into temporary

    # bounds check on the exit memory location
    li a4, LOGBUF       # load out of bounds memory address (LOGBUF)
    bge t2, a4, memory_error # error if the memory address is out of bounds

    la t1, EXIT         # load the codeword address into temporary
    sw t1, 0(t2)        # store the codeword address into HERE

    # move HERE pointer
    addi t2, t2, CELL   # prepare to move the HERE pointer by 1 CELL
    sw t2, 0(t0)        # store the new address of HERE into the HERE variable

    # update the STATE variable
    li t0, var_STATE    # load the address of the STATE variable into temporary
    sw zero, 0(t0)      # store the current state back into the STATE variable
    NEXT

memory_error:
    li t2, var_LATEST   # copy the memory address of LATEST into temporary
    lw t2, 0(t2)        # load the address value into temporary
    restorevars t2      # restore HERE and LATEST (t2)
    j err_mem
