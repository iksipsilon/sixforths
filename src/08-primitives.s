##
# Forth primitives: every word written in machine code
#
# CH32V006 PORT: one file, sorted by what the words do (inner interpreter,
# data stack, return stack, memory, arithmetic, logic, comparison, strings and
# parsing, compiler and dictionary, input and output, system). It merges
# upstream's 08-forth-primitives.s with the port's eForth-style and ANS-style
# additions. The dictionary is chained in file order and searched from the
# end, so a word near the end of this file is found fastest. The words for the lines in
# flash (line p load wipe) live with their machinery in 12-flash.s.
#
# Registers: s0 = DSP (data stack), tp = RSP (return stack), s1 = IP,
# a0 = W (NEXT hands W to the code-field routine like an argument). sp is the
# machine stack: interrupt frames and the return addresses of nested
# subroutines; a primitive leaves it as it found it. Everything else is
# scratch inside a primitive: t0-t2, a1-a5, gp. Prefer a1-a5 in new code
# (with s0 they allow 2-byte instructions where t0-t2 and gp do not).
#   t0 is clobbered by PUSH, PUSHRSP, POPRSP and checkunderflow (POP leaves
#   it alone). NEXT clobbers a5.
#   checkunderflow N*CELL guards N+1 items (checkunderflow 0 guards 1 item).
# Flags are -1 (true) / 0 (false). lw/sw trap on a misaligned address on the
# QingKe V2, so @ ! +! need CELL-aligned addresses; c@ c! and the block moves
# work at any address.
#
# NAMING: no word name may contain '(' or '\' -- the REPL's character loop in
# 09-interpreter.s swallows those as comment starters before they reach the
# TIB, so a word called (loop) could be defined but never typed. The loop
# runtime words are therefore called xdo, xloop and xplusloop.
##

##
# Code-field routines (not dictionary words: code fields point here)
##

.balign CELL
# docol: code-field action of a colon definition. NEXT leaves W (a0) = the
# code field address; the thread starts in the next cell.
docol:
    PUSHRSP s1          # push IP onto the return stack
    addi s1, a0, CELL   # skip code field in W by adding 1 CELL, store it in IP
    NEXT

# CREATEd words have this layout:   [header][code field][DOES> slot][data...]
# The DOES> slot (one cell, zero until DOES> fills it) costs 4 bytes per
# variable/constant but lets any CREATEd word become a DOES> word later.
# NEXT leaves W (a0) = the code field address on entry to all three actions.

.balign CELL
# dovar_code: code-field action of VARIABLE and CREATEd words ( -- pfa )
dovar_code:
    addi t1, a0, 2*CELL         # skip the code field and the DOES> slot
    PUSH t1
    NEXT

.balign CELL
# docon_code: code-field action of CONSTANT ( -- x )
docon_code:
    lw t1, 2*CELL(a0)
    PUSH t1
    NEXT

.balign CELL
# dodoes_code: code-field action of words whose defining word used DOES>
# ( -- pfa ) then runs the action thread whose address sits in the DOES> slot.
dodoes_code:
    PUSHRSP s1                  # like docol: save the caller's IP
    lw s1, CELL(a0)             # IP = the action thread
    addi t1, a0, 2*CELL         # pfa = first data cell
    PUSH t1
    NEXT

.balign CELL
# dovoc_code: code-field action of a vocabulary (fig-Forth's DOVOC): executing
# the vocabulary's name makes it the CONTEXT, the one searched first.
dovoc_code:
    addi t1, a0, 2*CELL         # its head cell = the first data cell
    li t2, var_CONTEXT
    sw t1, 0(t2)
    NEXT

##
# Inner interpreter: the words a thread is made of, and the code-field values
##

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

# execute ( cfa -- )    Execute the word whose code field address is on the stack
# CH32V006 PORT: takes a code field address now, which is what ' produces and
# what compiled cells contain. To execute the latest word: latest @ >cfa execute
defcode "execute",7,,EXECUTE
    checkunderflow 0    # need 1 item
    POP a0              # a0 = codeword address (docol relies on W = codeword)
    lw t0, 0(a0)        # load the body address
    jr t0               # jump to it; its NEXT continues the thread (no NEXT here)

# branch ( -- )         Unconditional: IP = cell at IP (compile-only, lay target with ,)
defcode "branch",6,,BRANCH
    lw s1, 0(s1)        # absolute target address stored in the next cell
    NEXT

# 0branch ( f -- )      Branch if the flag is zero, else skip the target cell
defcode "0branch",7,,ZBRANCH
    checkunderflow 0    # need 1 item
    POP t1
    bnez t1, zbranch_skip
    lw s1, 0(s1)        # take the branch: IP = target cell
    NEXT
zbranch_skip:
    addi s1, s1, CELL   # skip over the target cell
    NEXT

# xdo ( limit index -- ; R: -- fudge index+fudge )
defcode "xdo",3,,XDO
    checkunderflow CELL
    POP a2                      # index
    POP a1                      # limit
    li a3, 0x80000000
    sub a3, a3, a1              # fudge = 0x80000000 - limit
    add a2, a2, a3              # biased index
    PUSHRSP a3                  # fudge (PUSHRSP clobbers t0 only)
    PUSHRSP a2                  # biased index on top
    NEXT

# xloop ( -- ; R: sys sys -- | sys sys )   Step by 1; the next cell is the
# absolute branch target taken while looping
defcode "xloop",5,,XLOOP
    lw t1, 0(tp)                # biased index
    addi t2, t1, 1
    slt a1, t2, t1              # signed overflow of +1 <=> new < old
    bnez a1, xloop_done
    sw t2, 0(tp)
    lw s1, 0(s1)                # loop again: IP = target cell
    NEXT
xloop_done:
    addi tp, tp, 2*CELL         # drop the loop frame
    addi s1, s1, CELL           # skip the target cell
    NEXT

# xplusloop ( n -- ; R: sys sys -- | sys sys )   Step by n
# signed add overflow <=> (new < old) != (n < 0)
defcode "xplusloop",9,,XPLUSLOOP
    checkunderflow 0
    POP a2                      # n
    lw t1, 0(tp)                # biased index
    add t2, t1, a2
    slt a1, t2, t1
    slti a3, a2, 0
    xor a1, a1, a3
    bnez a1, xploop_done
    sw t2, 0(tp)
    lw s1, 0(s1)
    NEXT
xploop_done:
    addi tp, tp, 2*CELL
    addi s1, s1, CELL
    NEXT

# i ( -- n ; R: sys sys -- sys sys )   Innermost loop index
defcode "i",1,,IDX
    lw t1, 0(tp)
    lw t2, CELL(tp)
    sub t1, t1, t2
    PUSH t1
    NEXT

# j ( -- n )            Second loop index (the next loop out)
defcode "j",1,,JDX
    lw t1, 2*CELL(tp)
    lw t2, 3*CELL(tp)
    sub t1, t1, t2
    PUSH t1
    NEXT

# unloop ( -- ; R: sys sys -- )   Drop the loop frame (needed before exit)
defcode "unloop",6,,UNLOOP
    li t0, RSP_TOP-CELL         # need two cells on the return stack
    bge tp, t0, err_underflow
    addi tp, tp, 2*CELL
    NEXT

# litstring ( -- addr len )   Runtime of s": the thread holds a length cell, then
# the bytes, padded to a cell boundary. Pushes the string and steps IP over it.
defcode "litstring",9,,LITSTRING
    lw t1, 0(s1)                # length
    addi s1, s1, CELL           # IP -> first byte
    PUSH s1
    PUSH t1                     # (PUSH clobbers t0 only)
    add s1, s1, t1              # skip the bytes...
    addi s1, s1, CELL-1         # ...and round up to the next cell boundary
    andi s1, s1, -CELL
    NEXT

# dovar ( -- code )     The code-field value that makes a word push its pfa
defcode "dovar",5,,DOVARW
    la t1, dovar_code
    PUSH t1
    NEXT

# docon ( -- code )     The code-field value that makes a word push its cell
defcode "docon",5,,DOCONW
    la t1, docon_code
    PUSH t1
    NEXT

# docol ( -- code )     The code-field value of a colon definition
defcode "docol",5,,DOCOLW
    la t1, docol
    PUSH t1
    NEXT

# xdoes ( -- ; R: ret -- )   Runtime of DOES>. It sits inside a defining word,
# and the cells after it are the action thread. It repoints the newest word's
# code field at dodoes_code, records the action thread in the DOES> slot, then
# returns from the defining word (the thread after it must not run now).
#   : does> ' xdoes , ; immediate
defcode "xdoes",5,,XDOES
    li a0, var_CURRENT
    lw a0, 0(a0)
    lw a0, 0(a0)                # header of the word CREATE just made
    call to_cfa                 # a0 = its code field (clobbers t0)
    la t1, dodoes_code
    sw t1, 0(a0)                # code field -> dodoes_code
    sw s1, CELL(a0)             # DOES> slot = IP = the action thread
    POPRSP s1                   # return from the defining word
    NEXT

##
# Data stack
##

# drop ( x -- )         Discard the top of the data stack
defcode "drop",4,,DROP
    checkunderflow 0    # need 1 item
    addi s0, s0, CELL   # move the DSP up by 1 cell
    NEXT

# dup ( x -- x x )      Duplicate the top of the data stack
defcode "dup",3,,DUP
    checkunderflow 0    # need 1 item
    lw t1, 0(s0)        # load the top of the stack
    PUSH t1             # push a copy (PUSH clobbers t0)
    NEXT

# swap ( a b -- b a )   Exchange the top two items
defcode "swap",4,,SWAP
    checkunderflow CELL # need 2 items
    lw t1, 0(s0)        # b
    lw t2, CELL(s0)     # a
    sw t1, CELL(s0)
    sw t2, 0(s0)
    NEXT

# over ( a b -- a b a ) Push a copy of the second item
defcode "over",4,,OVER
    checkunderflow CELL # need 2 items
    lw t1, CELL(s0)     # a
    PUSH t1
    NEXT

# rot ( a b c -- b c a )
defcode "rot",3,,ROT
    checkunderflow 2*CELL
    lw t1, 0(s0)                # c
    lw t2, CELL(s0)             # b
    lw a1, 2*CELL(s0)           # a
    sw a1, 0(s0)
    sw t1, CELL(s0)
    sw t2, 2*CELL(s0)
    NEXT

# nip ( a b -- b )
defcode "nip",3,,NIP
    checkunderflow CELL
    lw t1, 0(s0)
    addi s0, s0, CELL
    sw t1, 0(s0)
    NEXT

# 2dup ( a b -- a b a b )
defcode "2dup",4,,TWODUP
    checkunderflow CELL
    lw t1, 0(s0)                # b
    lw t2, CELL(s0)             # a
    PUSH t2
    PUSH t1
    NEXT

# 2drop ( a b -- )
defcode "2drop",5,,TWODROP
    checkunderflow CELL
    addi s0, s0, 2*CELL
    NEXT

# ?dup ( x -- 0 | x x )
defcode "?dup",4,,QDUP
    checkunderflow 0
    lw t1, 0(s0)
    beqz t1, qdup_done
    PUSH t1
qdup_done:
    NEXT

# sp@ ( -- addr )       Get current data stack pointer (the address of the
# top cell before sp@ pushed its result)
defcode "sp@",3,,DSPFETCH
    mv t1, s0           # PUSH moves the DSP before it stores, hence the copy
    PUSH t1             # store DSP in the top of the stack
    NEXT

# sp! ( a -- )          Set the data stack pointer. CH32V006 PORT: a must be
# CELL-aligned and inside the data stack (r0 ... s0), else it is an error:
# an unaligned pointer would trap at the next push.
defcode "sp!",3,,DSPSTORE
    checkunderflow 0    # need 1 item
    POP a1
    andi t0, a1, CELL-1
    bnez t0, err_error
    li t0, RSP_TOP
    bltu a1, t0, err_error
    li t0, DSP_TOP
    bgtu a1, t0, err_error
    mv s0, a1
    NEXT

# s0 ( -- a )           Address just above the data stack's first cell
# depth is then:  : depth s0 sp@ - 2/ 2/ 1- ;
defcode "s0",2,,SZERO
    li t1, DSP_TOP
    PUSH t1
    NEXT

# depth ( -- n )        Number of cells on the data stack
defcode "depth",5,,DEPTH
    li t1, DSP_TOP
    sub t1, t1, s0              # bytes in use
    srai t1, t1, 2              # cells
    PUSH t1
    NEXT

##
# Return stack
##

# >r ( x -- ; R: -- x ) Move top of data stack to the return stack
defcode ">r",2,,TOR
    checkunderflow 0    # need 1 item
    POP t1
    PUSHRSP t1          # (PUSHRSP clobbers t0)
    NEXT

# r> ( -- x ; R: x -- ) Move top of return stack to the data stack
defcode "r>",2,,FROMR
    POPRSP t1           # (POPRSP checks RSP underflow, clobbers t0)
    PUSH t1
    NEXT

# r@ ( -- x ; R: x -- x ) Copy the top of the return stack
defcode "r@",2,,RFETCH
    li t0, RSP_TOP              # RSP underflow check without popping
    bge tp, t0, err_underflow
    lw t1, 0(tp)
    PUSH t1
    NEXT

# rp@ ( -- addr )       Get current return stack pointer
defcode "rp@",3,,RSPFETCH
    PUSH tp             # store RSP in the top of the stack
    NEXT

# rp! ( a -- )          Set the return stack pointer. CH32V006 PORT: a must be
# CELL-aligned and inside the return stack (up to r0), else it is an error.
defcode "rp!",3,,RSPSTORE
    checkunderflow 0    # need 1 item
    POP a1
    andi t0, a1, CELL-1
    bnez t0, err_error
    li t0, TIB_TOP
    bltu a1, t0, err_error
    li t0, RSP_TOP
    bgtu a1, t0, err_error
    mv tp, a1
    NEXT

# r0 ( -- a )           Address just above the return stack's first cell
defcode "r0",2,,RZERO
    li t1, RSP_TOP
    PUSH t1
    NEXT

##
# Memory
##

# @ ( addr -- x )       Fetch memory at addr
defcode "@",1,,FETCH
    checkunderflow 0    # check for stack underflow of data stack (1 CELL)
    lw t0, 0(s0)        # load the top of stack into temporary
    lw t0, 0(t0)        # load the value from the temporary (addr)
    sw t0, 0(s0)        # store the value back the top of stack (x)
    NEXT

# ! ( x addr -- )       Store x at addr
defcode "!",1,,STORE
    checkunderflow CELL # check for stack underflow of data stack (2 CELLs)
    lw t1, 0(s0)        # load the DSP value (addr) into temporary
    lw t0, CELL(s0)     # load the DSP value (x) into temporary
    sw t0, 0(t1)        # store x into addr
    addi s0, s0, 2*CELL # move DSP up by 2 cells
    NEXT

# c@ ( a -- c )         Fetch one byte from address a
defcode "c@",2,,CFETCH
    checkunderflow 0    # need 1 item
    lw t1, 0(s0)        # load the address
    lbu t1, 0(t1)       # load the byte (any alignment is fine for lbu)
    sw t1, 0(s0)        # replace the top of the stack in place
    NEXT

# c! ( c a -- )         Store the byte c at address a
defcode "c!",2,,CSTORE
    checkunderflow CELL # need 2 items
    POP t1              # address
    POP t2              # byte value
    sb t2, 0(t1)
    NEXT

# +! ( n a -- )         Add n to the cell at a (a must be CELL-aligned)
defcode "+!",2,,PLUSSTORE
    checkunderflow CELL
    POP t1                      # address
    POP t2                      # n
    lw a1, 0(t1)
    add a1, a1, t2
    sw a1, 0(t1)
    NEXT

# cmove ( src dst u -- )    Copy u bytes, lowest address first (any alignment)
defcode "cmove",5,,CMOVE
    checkunderflow 2*CELL
    POP t1                      # u
    POP t2                      # dst
    POP a1                      # src
cmove_loop:
    beqz t1, cmove_done
    lbu a2, 0(a1)
    sb a2, 0(t2)
    addi a1, a1, 1
    addi t2, t2, 1
    addi t1, t1, -1
    j cmove_loop
cmove_done:
    NEXT

# cmove> ( src dst u -- )   Copy u bytes, highest address first (overlap-safe
# when dst > src)
defcode "cmove>",6,,CMOVEUP
    checkunderflow 2*CELL
    POP t1                      # u
    POP t2                      # dst
    POP a1                      # src
    add t2, t2, t1              # one past the last byte
    add a1, a1, t1
cmoveup_loop:
    beqz t1, cmoveup_done
    addi t2, t2, -1
    addi a1, a1, -1
    lbu a2, 0(a1)
    sb a2, 0(t2)
    addi t1, t1, -1
    j cmoveup_loop
cmoveup_done:
    NEXT

# fill ( a u c -- )     Set u bytes at a to c
defcode "fill",4,,FILL
    checkunderflow 2*CELL
    POP t1                      # c
    POP t2                      # u
    POP a1                      # a
fill_loop:
    beqz t2, fill_done
    sb t1, 0(a1)
    addi a1, a1, 1
    addi t2, t2, -1
    j fill_loop
fill_done:
    NEXT

# here ( -- addr )      Store HERE variable address in top of data stack
defcode "here",4,,HERE
    li t1, var_HERE     # load variable into temporary
    PUSH t1
    NEXT

# pad ( -- a )          Start of the 256-byte scratch area
defcode "pad",3,,PADADDR
    li t1, PAD
    PUSH t1
    NEXT

# allot ( n -- )        Reserve n bytes at HERE. Bounds-checked like `,`.
# HERE may end up unaligned: `,`, `:` and `create` round it up themselves, but
# a cell laid down by the compiler inside a definition does not, so write
# align  after `[ n allot ]` in a colon definition.
defcode "allot",5,,ALLOT
    checkunderflow 0
    POP t1
    li t2, var_HERE
    lw a4, 0(t2)
    add a4, a4, t1
    li a5, DICT_TOP
    bge a4, a5, err_mem
    sw a4, 0(t2)
    NEXT

# , ( x -- )            Append a cell to the dictionary at HERE. An unaligned
# HERE (after `c,` or an odd `allot`) is rounded up first: the store would
# trap otherwise.
defcode ",",1,,COMMA
    checkunderflow 0    # need 1 item
    POP t1
    li t2, var_HERE
    lw a4, 0(t2)        # current HERE value
    addi a4, a4, CELL-1 # round it up to a CELL boundary
    andi a4, a4, -CELL
    li a5, DICT_TOP     # dictionary bounds check, like COLON's
    bge a4, a5, err_mem
    sw t1, 0(a4)        # store the cell
    addi a4, a4, CELL
    sw a4, 0(t2)        # advance HERE
    NEXT

# c, ( c -- )           Append one byte to the dictionary at HERE. HERE is left
# unaligned; `,`, `:` and `create` round it up, or use align.
defcode "c,",2,,CCOMMA
    checkunderflow 0
    POP a1
    li t2, var_HERE
    lw a4, 0(t2)
    li a5, DICT_TOP             # dictionary bounds check, like `,`
    bge a4, a5, err_mem
    sb a1, 0(a4)
    addi a4, a4, 1
    sw a4, 0(t2)
    NEXT

# align ( -- )          Round HERE up to the next CELL boundary
defcode "align",5,,ALIGN
    li t2, var_HERE
    lw a4, 0(t2)
    addi a4, a4, CELL-1
    andi a4, a4, -CELL
    sw a4, 0(t2)
    NEXT

# move ( src dst u -- ) Copy u bytes; the regions may overlap either way
defcode "move",4,,MOVE
    checkunderflow 2*CELL
    lw a1, 2*CELL(s0)           # src
    lw a2, CELL(s0)             # dst
    bltu a1, a2, code_CMOVEUP   # dst above src: copy from the top down
    j code_CMOVE                # otherwise from the bottom up

##
# Arithmetic
##

# + ( x1 x2 -- n )      Add the two values at the top of the stack
defcode "+",1,,ADD
    checkunderflow CELL # check for stack underflow of data stack (2 CELLs)
    POP t0              # pop DSP value (x1) into temporary
    lw t1, 0(s0)        # load DSP value (x2) into temporary
    add t0, t0, t1      # add the two values
    sw t0, 0(s0)        # store the value into the top of the stack
    NEXT

# - ( a b -- a-b )      Subtraction
defcode "-",1,,SUB
    checkunderflow CELL # need 2 items
    POP t1              # b
    lw t2, 0(s0)        # a
    sub t2, t2, t1
    sw t2, 0(s0)
    NEXT

# * ( n1 n2 -- n3 )     Low 32 bits of the product (Zmmul `mul`)
defcode "*",1,,MUL
    checkunderflow CELL
    POP t1
    lw t2, 0(s0)
    mul t2, t2, t1
    sw t2, 0(s0)
    NEXT

# 1+ ( n -- n+1 )
defcode "1+",2,,ONEPLUS
    checkunderflow 0
    lw t1, 0(s0)
    addi t1, t1, 1
    sw t1, 0(s0)
    NEXT

# 1- ( n -- n-1 )
defcode "1-",2,,ONEMINUS
    checkunderflow 0
    lw t1, 0(s0)
    addi t1, t1, -1
    sw t1, 0(s0)
    NEXT

# 2* ( x -- x*2 )
defcode "2*",2,,TWOSTAR
    checkunderflow 0
    lw t1, 0(s0)
    slli t1, t1, 1
    sw t1, 0(s0)
    NEXT

# 2/ ( n -- n/2 )       Arithmetic shift: the sign is preserved
defcode "2/",2,,TWOSLASH
    checkunderflow 0
    lw t1, 0(s0)
    srai t1, t1, 1
    sw t1, 0(s0)
    NEXT

# negate ( n -- -n )
defcode "negate",6,,NEGATE
    checkunderflow 0
    lw t1, 0(s0)
    neg t1, t1
    sw t1, 0(s0)
    NEXT

# abs ( n -- |n| )
defcode "abs",3,,ABS
    checkunderflow 0
    lw t1, 0(s0)
    srai t2, t1, 31             # all ones if negative
    xor t1, t1, t2
    sub t1, t1, t2
    sw t1, 0(s0)
    NEXT

# min ( a b -- a|b )    Signed
defcode "min",3,,MIN
    checkunderflow CELL
    POP t1                      # b
    lw t2, 0(s0)                # a
    blt t2, t1, min_keep
    mv t2, t1
min_keep:
    sw t2, 0(s0)
    NEXT

# max ( a b -- a|b )    Signed
defcode "max",3,,MAX
    checkunderflow CELL
    POP t1                      # b
    lw t2, 0(s0)                # a
    blt t1, t2, max_keep
    mv t2, t1
max_keep:
    sw t2, 0(s0)
    NEXT

# cells ( n -- n*4 )
defcode "cells",5,,CELLS
    checkunderflow 0
    lw t1, 0(s0)
    slli t1, t1, 2
    sw t1, 0(s0)
    NEXT

# cell+ ( a -- a+4 )
defcode "cell+",5,,CELLPLUS
    checkunderflow 0
    lw t1, 0(s0)
    addi t1, t1, CELL
    sw t1, 0(s0)
    NEXT

# um* ( u1 u2 -- lo hi )   Unsigned 32x32 -> 64 multiply, hi on top.
# Built from four 16x16 `mul`s so it needs nothing beyond the base Zmmul `mul`
# (no mulhu): result = p00 + (p01+p10)<<16 + p11<<32, with the carries of the
# middle sum and of the low add folded into the high word.
defcode "um*",3,,UMSTAR
    checkunderflow CELL
    lw a1, 0(s0)                # b
    lw a2, CELL(s0)             # a
    srli a3, a1, 16             # b1
    slli a1, a1, 16
    srli a1, a1, 16             # b0
    srli a4, a2, 16             # a1h
    slli a2, a2, 16
    srli a2, a2, 16             # a0
    mul t1, a2, a1              # p00 = a0*b0
    mul t2, a2, a3              # p01 = a0*b1
    mul a2, a4, a1              # p10 = a1h*b0   (a2 is free: a0 is spent)
    mul a4, a4, a3              # p11 = a1h*b1
    add t2, t2, a2              # mid = p01 + p10 (33 bits: carry may be lost)
    sltu a2, t2, a2             # carry out of the middle sum
    slli a2, a2, 16             # ...lands at bit 16 of the high word
    srli a3, t2, 16             # mid >> 16
    add a3, a3, a2
    add a4, a4, a3              # hi = p11 + (mid>>16) + carry<<16
    slli a3, t2, 16             # mid << 16
    add t1, t1, a3              # lo = p00 + (mid<<16)
    sltu a3, t1, a3             # carry out of the low add
    add a4, a4, a3              # hi += carry
    sw t1, CELL(s0)             # lo (deeper)
    sw a4, 0(s0)                # hi (top)
    NEXT

.balign CELL
# udiv64: unsigned 64/32 division, 32-step restoring (shift and subtract: the
# QingKe V2C has no divide instruction).
# arguments: a1 = dividend low, t1 = dividend high, a2 = divisor
# returns: a1 = quotient, t1 = remainder
# Needs high < divisor for a 32-bit quotient (otherwise the quotient wraps).
# A divisor of 0 gives quotient -1 instead of trapping. The 33-bit case
# (remainder shifts a 1 out of bit 31) is handled explicitly, so divisors
# >= 2^31 work.
# clobbers: t2, a3, a4
udiv64:
    li t2, 32                   # bit counter
udiv64_loop:
    srli a3, a1, 31             # next dividend bit
    srli a4, t1, 31             # bit about to fall out of the remainder
    slli a1, a1, 1              # bit 0 is now the quotient slot
    slli t1, t1, 1
    or t1, t1, a3
    bnez a4, udiv64_sub         # 33-bit remainder is always >= divisor
    bltu t1, a2, udiv64_next
udiv64_sub:
    sub t1, t1, a2
    ori a1, a1, 1               # quotient bit = 1
udiv64_next:
    addi t2, t2, -1
    bnez t2, udiv64_loop
    ret

.balign CELL
# sdivmod: signed 32/32 division, truncating (the quotient rounds toward
# zero and the remainder takes the sign of the dividend, like C).
# arguments: a1 = dividend, a2 = divisor
# returns: a1 = quotient, t1 = remainder
# clobbers: t0, t2, a2, a3, a4, a5, gp
sdivmod:
    addi sp, sp, -CELL          # udiv64 is called below: ra goes on the
    sw ra, 0(sp)                # machine stack
    mv gp, a1                   # the dividend's sign is the remainder's
    xor a5, a1, a2              # sign of the quotient
    srai t0, a1, 31
    xor a1, a1, t0
    sub a1, a1, t0              # |dividend|
    srai t0, a2, 31
    xor a2, a2, t0
    sub a2, a2, t0              # |divisor|
    li t1, 0
    call udiv64
    bgez a5, sdivmod_rem
    neg a1, a1
sdivmod_rem:
    bgez gp, sdivmod_done
    neg t1, t1
sdivmod_done:
    lw ra, 0(sp)
    addi sp, sp, CELL
    ret

# um/mod ( lo hi u -- rem quot )   Unsigned 64/32 division. Needs hi < u.
# u = 0 gives quot = -1 instead of trapping.
defcode "um/mod",6,,UMDIVMOD
    checkunderflow 2*CELL
    lw a2, 0(s0)                # divisor
    lw t1, CELL(s0)             # hi -> becomes the remainder
    lw a1, 2*CELL(s0)           # lo -> becomes the quotient
    call udiv64
    addi s0, s0, CELL           # 3 in, 2 out
    sw t1, CELL(s0)             # remainder
    sw a1, 0(s0)                # quotient on top
    NEXT

# u/mod ( u1 u2 -- rem quot )   Unsigned 32/32 division
defcode "u/mod",5,,UDIVMOD
    checkunderflow CELL
    lw a2, 0(s0)                # divisor
    lw a1, CELL(s0)             # dividend
    li t1, 0
    call udiv64
    sw t1, CELL(s0)             # remainder
    sw a1, 0(s0)                # quotient on top
    NEXT

# /mod ( n1 n2 -- rem quot )   Signed division, truncating: -7 2 /mod gives
# -1 -3. n2 = 0 does not trap.
defcode "/mod",4,,DIVMOD
    checkunderflow CELL
    lw a2, 0(s0)                # divisor
    lw a1, CELL(s0)             # dividend
    call sdivmod
    sw t1, CELL(s0)             # remainder
    sw a1, 0(s0)                # quotient on top
    NEXT

# / ( n1 n2 -- quot )
defcode "/",1,,DIV
    checkunderflow CELL
    POP a2                      # divisor
    lw a1, 0(s0)                # dividend
    call sdivmod
    sw a1, 0(s0)
    NEXT

# mod ( n1 n2 -- rem )
defcode "mod",3,,MOD
    checkunderflow CELL
    POP a2                      # divisor
    lw a1, 0(s0)                # dividend
    call sdivmod
    sw t1, 0(s0)
    NEXT

# lshift ( x u -- x<<u )  The core uses the low 5 bits of u: u >= 32 wraps.
defcode "lshift",6,,LSHIFT
    checkunderflow CELL
    POP t1                      # u
    lw t2, 0(s0)                # x
    sll t2, t2, t1
    sw t2, 0(s0)
    NEXT

# rshift ( x u -- x>>u )  Logical shift. Same u >= 32 caveat as lshift.
defcode "rshift",6,,RSHIFT
    checkunderflow CELL
    POP t1                      # u
    lw t2, 0(s0)                # x
    srl t2, t2, t1
    sw t2, 0(s0)
    NEXT

##
# Logic
##

# and ( a b -- a&b )
defcode "and",3,,AND
    checkunderflow CELL # need 2 items
    POP t1
    lw t2, 0(s0)
    and t2, t2, t1
    sw t2, 0(s0)
    NEXT

# or ( a b -- a|b )
defcode "or",2,,OR
    checkunderflow CELL # need 2 items
    POP t1
    lw t2, 0(s0)
    or t2, t2, t1
    sw t2, 0(s0)
    NEXT

# xor ( a b -- a^b )
defcode "xor",3,,XOR
    checkunderflow CELL # need 2 items
    POP t1
    lw t2, 0(s0)
    xor t2, t2, t1
    sw t2, 0(s0)
    NEXT

# invert ( n -- ~n )    Bitwise complement (convenience; = -1 xor)
defcode "invert",6,,INVERT
    checkunderflow 0    # need 1 item
    lw t1, 0(s0)
    xori t1, t1, -1
    sw t1, 0(s0)
    NEXT

##
# Comparison (all return -1 / 0)
##

# 0= ( x -- f )         -1 if top of stack is 0, 0 otherwise
defcode "0=",2,,ZEQU
    checkunderflow 0    # check for stack underflow of data stack (1 CELL)
    lw t0, 0(s0)        # load the DSP value (x) into temporary
    snez t0, t0         # store 0 in temporary if it's equal to 0, otherwise store 1
    addi t0, t0, -1     # store -1 in temporary if it's 0, otherwise store 0
    sw t0, 0(s0)        # store value back into the top of the stack
    NEXT

# 0< ( n -- f )         True (-1) if n is negative, else 0 (eForth's only compare)
defcode "0<",2,,ZLESS
    checkunderflow 0    # need 1 item
    lw t1, 0(s0)
    srai t1, t1, 31     # arithmetic shift: sign bit fills the word
    sw t1, 0(s0)
    NEXT

# 0> ( n -- f )         True if n is positive
defcode "0>",2,,ZGREATER
    checkunderflow 0
    lw t1, 0(s0)
    sgtz t1, t1
    neg t1, t1
    sw t1, 0(s0)
    NEXT

# = ( a b -- f )
defcode "=",1,,EQUAL
    checkunderflow CELL
    POP t1
    lw t2, 0(s0)
    sub t2, t2, t1
    seqz t2, t2
    neg t2, t2
    sw t2, 0(s0)
    NEXT

# <> ( a b -- f )
defcode "<>",2,,NOTEQUAL
    checkunderflow CELL
    POP t1
    lw t2, 0(s0)
    sub t2, t2, t1
    snez t2, t2
    neg t2, t2
    sw t2, 0(s0)
    NEXT

# < ( a b -- f )       Signed
defcode "<",1,,LESS
    checkunderflow CELL
    POP t1                      # b
    lw t2, 0(s0)                # a
    slt t2, t2, t1
    neg t2, t2
    sw t2, 0(s0)
    NEXT

# > ( a b -- f )       Signed
defcode ">",1,,GREATER
    checkunderflow CELL
    POP t1
    lw t2, 0(s0)
    slt t2, t1, t2
    neg t2, t2
    sw t2, 0(s0)
    NEXT

# u< ( u1 u2 -- f )
defcode "u<",2,,ULESS
    checkunderflow CELL
    POP t1
    lw t2, 0(s0)
    sltu t2, t2, t1
    neg t2, t2
    sw t2, 0(s0)
    NEXT

# u> ( u1 u2 -- f )
defcode "u>",2,,UGREATER
    checkunderflow CELL
    POP t1
    lw t2, 0(s0)
    sltu t2, t1, t2
    neg t2, t2
    sw t2, 0(s0)
    NEXT

##
# Strings and parsing
##

# parse-name ( -- addr len )   Next space-delimited token from the TIB, advancing
# >in. len = 0 when the line is exhausted.
defcode "parse-name",10,,PARSENAME
    call token                  # a0 = token start, a1 = token length; TOIN moves past it
    PUSH a0
    PUSH a1
    NEXT

# parse ( c -- addr len )   Text up to the next c (or the end of the line) from
# the TIB, advancing >in past the closing c. One leading space is skipped: it is
# the delimiter that ended the previous token (TOIN points AT it here), so
#   : ." 34 parse ... ; immediate
# sees the text starting right after `." `, like ANS.
defcode "parse",5,,PARSE
    checkunderflow 0
    POP a3                      # delimiter
    li t2, TIB_BOTTOM
    li a4, var_TOIN
    lw a0, 0(a4)
    add a0, a0, t2              # a0 = parse position
    lbu t0, 0(a0)
    li t1, CHAR_SPACE
    bne t0, t1, parse_start
    addi a0, a0, 1              # skip the one delimiter after the previous token
parse_start:
    mv a1, a0                   # a1 = start of the text
    li a5, TIB_TOP
parse_scan:
    bgeu a0, a5, parse_eol      # never scan past the TIB
    lbu t0, 0(a0)
    beqz t0, parse_eol          # the TIB is zero-filled beyond the line
    beq t0, a3, parse_hit
    addi a0, a0, 1
    j parse_scan
parse_hit:
    sub t1, a0, a1              # length
    addi a0, a0, 1              # step past the closing delimiter
    j parse_store
parse_eol:
    sub t1, a0, a1
parse_store:
    sub t0, a0, t2              # new >in = a0 - TIB
    sw t0, 0(a4)
    PUSH a1
    PUSH t1
    NEXT

# number ( addr len -- n unparsed )   Wraps the interpreter's number routine:
# decimal, or hex with a 0x prefix (uppercase A-F), optional leading '-'.
# unparsed = 0 means the whole string was a number. n is meaningful only then:
# the routine multiplies by the base before it checks the next character, so a
# partial parse leaves a value that is ten times too large. An empty string is
# reported as unparsed = 1.
defcode "number",6,,NUMBER
    checkunderflow CELL
    POP a1                      # length
    POP a0                      # address
    beqz a1, numw_bad
    call number
    j numw_push
numw_bad:
    li a0, 0
    li a1, 1
numw_push:
    PUSH a0
    PUSH a1
    NEXT

# find-name ( addr len -- header | 0 )   Dictionary search in the same order
# as the interpreter: the context vocabulary, then FORTH. Unlike the
# interpreter's own lookup, a miss returns 0 instead of aborting. Hidden words
# are skipped. The result is a header address: feed it to >cfa for the xt, or
# read the flags with  4 + c@  (bit 7 = immediate).
defcode "find-name",9,,FINDNAME
    checkunderflow CELL
    POP a1                      # length
    POP a0                      # name address
    call search_order           # a2 = header or 0
    PUSH a2
    NEXT

# find-name-in ( addr len voc -- header | 0 )   Search one vocabulary only (no
# fall-through to FORTH). voc is the address of its head cell:  ' name >body
# for a vocabulary made with `vocabulary`,  context @  for the current one.
# This is the word for looking a key binding up in the phone's current mode
# without touching CONTEXT, which belongs to the text interpreter.
defcode "find-name-in",12,,FINDNAMEIN
    checkunderflow 2*CELL
    POP a2                      # head cell of the vocabulary
    POP a1                      # length
    POP a0                      # name address
    lw a2, 0(a2)                # its newest word
    call search_chain           # a2 = header or 0
    PUSH a2
    NEXT

# count ( a -- a+1 u )  Split a counted string into its text and its length
defcode "count",5,,COUNT
    checkunderflow 0
    lw a1, 0(s0)
    lbu a2, 0(a1)               # the count byte
    addi a1, a1, 1
    sw a1, 0(s0)
    PUSH a2
    NEXT

# type ( a u -- )       Send u characters starting at a to the output
defcode "type",4,,TYPE
    checkunderflow CELL
    POP a2                      # u
    POP a1                      # a
    add a2, a1, a2              # out_print wants start and end
    call out_print              # (clobbers a0, a1, t0, t1)
    NEXT

# s= ( a1 a2 u -- f )   True if the u bytes at a1 and at a2 are the same
# (u = 0: true). For matching what the modem sent against a known text:
#   line s" RING" s=      (s" leaves its length on top, which is the u here)
# Not CamelForth's S=, which returns a difference instead of a flag.
defcode "s=",2,,SEQUAL
    checkunderflow 2*CELL
    POP a3                      # u
    POP a2                      # a2
    lw a1, 0(s0)                # a1
    li t1, -1                   # equal until a byte differs
sequal_loop:
    beqz a3, sequal_done
    lbu a4, 0(a1)
    lbu a5, 0(a2)
    bne a4, a5, sequal_diff
    addi a1, a1, 1
    addi a2, a2, 1
    addi a3, a3, -1
    j sequal_loop
sequal_diff:
    li t1, 0
sequal_done:
    sw t1, 0(s0)
    NEXT

# scan ( a u c -- a' u' )   Step forward to the first character c. a' points
# at it and u' counts it and everything after it; u' = 0 if c is not there.
defcode "scan",4,,SCAN
    checkunderflow 2*CELL
    POP a3                      # c
    lw a2, 0(s0)                # u
    lw a1, CELL(s0)             # a
scan_loop:
    beqz a2, scan_done
    lbu a4, 0(a1)
    beq a4, a3, scan_done
    addi a1, a1, 1
    addi a2, a2, -1
    j scan_loop
scan_done:
    sw a1, CELL(s0)
    sw a2, 0(s0)
    NEXT

# /string ( a u n -- a+n u-n )   Drop the first n characters of a string
defcode "/string",7,,SLASHSTRING
    checkunderflow 2*CELL
    POP a3                      # n
    lw a2, 0(s0)                # u
    lw a1, CELL(s0)             # a
    add a1, a1, a3
    sub a2, a2, a3
    sw a1, CELL(s0)
    sw a2, 0(s0)
    NEXT

##
# Compiler and dictionary
##

# : ( -- )              # Start the definition of a new word
defcode ":",1,,COLON
    call token                  # a0 = token start, a1 = token length; TOIN moves past it

    # bounds checks on token size
    beqz a1, err_ok     # ok if token size is 0
    li t0, F_LENMASK    # load max token size (31: 5 length bits) in temporary
    bgtu a1, t0, err_token # error if token size is greater than 31

    # CH32V006 PORT: a jonesforth-style header instead of a hashed one: link
    # cell, flags+length byte (HIDDEN while compiling), the name, zero padding
    # to the next CELL boundary, then the code field: docol, the same value a
    # defword header holds (upstream pointed it at a `j docol` stub, one
    # extra jump for every call of a colon word). make_header builds it, as
    # for create, and checks that it fits.
    la a2, docol
    li a3, F_HIDDEN
    call make_header

    # update STATE variable
    li t0, var_STATE    # load the address of the STATE variable into temporary
    li t1, 1            # set the STATE variable to compile mode (1 = compile)
    sw t1, 0(t0)        # store the current state back into the STATE variable
    NEXT

# ; ( -- )              # End the definition of a new word
defcode ";",1,F_IMMEDIATE,SEMI
    # CH32V006 PORT BUGFIX: check for room first and unhide after. The word
    # used to be unhidden first, so a `;` that found the dictionary full left
    # the unfinished word (with no EXIT) defined: abandon_def drops only a
    # hidden word.
    li t0, var_HERE     # copy the memory address of HERE into temporary
    lw t2, 0(t0)        # load the HERE value into temporary

    # bounds check on the exit memory location
    li a4, DICT_TOP     # load out of bounds memory address (DICT_TOP)
    bge t2, a4, err_mem # error if the memory address is out of bounds
                        # (reset then drops the unfinished word: abandon_def)

    # unhide the word
    li a1, var_CURRENT  # the word being compiled is the newest of CURRENT
    lw a1, 0(a1)        # load the address of the head cell
    lw a1, 0(a1)        # load the address of the word
    lbu t1, CELL(a1)    # load the flags+length byte into temporary
    andi t1, t1, ~F_HIDDEN # unhide the word
    sb t1, CELL(a1)     # write the flags+length byte back to memory

    # store codeword into memory

    la t1, EXIT         # load the codeword address into temporary
    sw t1, 0(t2)        # store the codeword address into HERE

    # move HERE pointer
    addi t2, t2, CELL   # prepare to move the HERE pointer by 1 CELL
    sw t2, 0(t0)        # store the new address of HERE into the HERE variable

    # update the STATE variable
    li t0, var_STATE    # load the address of the STATE variable into temporary
    sw zero, 0(t0)      # store the current state back into the STATE variable
    NEXT

# [ ( -- )              Switch to interpret state (immediate)
defcode "[",1,F_IMMEDIATE,LBRAC
    li t1, var_STATE
    sw zero, 0(t1)
    NEXT

# ] ( -- )              Switch to compile state
defcode "]",1,,RBRAC
    li t1, var_STATE
    li t2, 1
    sw t2, 0(t1)
    NEXT

# dovoc ( -- code )     The code-field value that makes a word a vocabulary
defcode "dovoc",5,,DOVOCW
    la t1, dovoc_code
    PUSH t1
    NEXT

# create ( "name" -- )  Build a header at HERE; the word pushes its pfa (the
# first data cell, after the code field and the DOES> slot) when executed.
#   : variable create 0 , ;
#   : constant create , docon latest @ >cfa ! ;
defcode "create",6,,CREATE
    call token                  # a0 = token start, a1 = token length; TOIN moves past it
    beqz a1, err_error          # create with no name
    li t0, F_LENMASK
    bgtu a1, t0, err_token      # name longer than 31 characters
    la a2, dovar_code
    li a3, 0                    # not hidden
    call make_header            # (its bounds check already covers the slot)
    li t0, var_HERE
    lw t1, 0(t0)
    sw zero, 0(t1)              # the DOES> slot
    addi t1, t1, CELL
    sw t1, 0(t0)
    NEXT

# immediate ( -- )      Mark the most recently defined word as IMMEDIATE.
# The interpreter already honors F_IMMEDIATE in compile mode (that is how ';'
# works), so setting the flag on the LATEST word is all that is needed.
# Usage, standard Forth style:  : name ... ; immediate
defcode "immediate",9,,IMMEDIATE
    li t1, var_CURRENT
    lw t1, 0(t1)
    lw t1, 0(t1)        # address of the most recent word
    lbu t2, CELL(t1)    # its flags+length byte
    ori t2, t2, F_IMMEDIATE # set the immediate bit
    sb t2, CELL(t1)
    NEXT

# ' ( -- cfa )          Tick: parse the next token and resolve it in the
# dictionary. State-smart (and itself IMMEDIATE):
#   executing:  push the word's code field address
#   compiling:  compile it as a literal (LIT + cfa)
# CH32V006 PORT: with jonesforth-style headers ' returns the code field
# address directly (the thing compiled cells contain and execute consumes),
# so user code never does header arithmetic. Control flow in Forth is now:
#   : begin here @ ; immediate
#   : until ' 0branch , , ; immediate
defcode "'",1,F_IMMEDIATE,TICK
    # parse the next token, mirroring process_token's use of TOIN
    call token                  # a0 = token start, a1 = token length; TOIN moves past it
    beqz a1, err_error  # ' with nothing after it
    call lookup         # by name: a0 = token address, a1 = length; returns
                        # a1 = word header address (errors out if not found)
    mv a0, a1
    call to_cfa         # a0 = code field address
    # state-smart: push when executing, compile a literal when compiling
    li t1, var_STATE
    lw t1, 0(t1)
    beqz t1, tick_push
    la t1, LIT          # compile: LIT codeword cell, then the cfa cell
    li t2, var_HERE
    lw a4, 0(t2)
    li a5, DICT_TOP-CELL # need room for two cells
    bge a4, a5, err_mem
    sw t1, 0(a4)
    sw a0, CELL(a4)
    addi a4, a4, 2*CELL
    sw a4, 0(t2)        # advance HERE
    NEXT
tick_push:
    PUSH a0
    NEXT

# ['] ( "name" -- cfa )   Immediate alias of the state-smart ': inside a colon
# definition it compiles the next word's code field address as a literal.
defcode "[']",3,F_IMMEDIATE,BTICK
    j code_TICK

# >cfa ( wa -- cfa )    Convert a word header address (e.g. latest @) to its
# code field address, skipping the link, the flags+length byte, the name,
# and the alignment padding (jonesforth >CFA).
defcode ">cfa",4,,TCFA
    checkunderflow 0    # need 1 item
    lw a0, 0(s0)        # load the header address from the top of the stack
    call to_cfa         # a0 = code field address (clobbers t0, ra)
    sw a0, 0(s0)        # store it back on the stack
    NEXT

# latest ( -- addr )     Address of the cell that holds the newest word of the
# vocabulary definitions go to (so  latest @  is the word just defined). In
# FORTH that cell is the LATEST variable; in another vocabulary, its head cell.
defcode "latest",6,,LATEST
    li t1, var_CURRENT
    lw t1, 0(t1)
    PUSH t1
    NEXT

# state ( -- addr )     Store STATE variable address in top of data stack
defcode "state",5,,STATE
    li t1, var_STATE    # load variable into temporary
    PUSH t1
    NEXT

# words ( -- )          List the names of all visible words of the context
# vocabulary, newest first (FORTH unless a vocabulary was selected:
# `edit words forth` lists the bindings of edit).
defcode "words",5,,WORDS
    li a3, var_CONTEXT  # a3 (Z) survives out_print/out_put (they clobber
    lw a3, 0(a3)        # only a0-a2, t0, t1, ra) so it holds the chain pointer
    lw a3, 0(a3)        # newest word of the context vocabulary
words_loop:
    beqz a3, words_done # end of the dictionary: link is 0
    lbu t0, CELL(a3)    # load the flags+length byte
    andi t1, t0, F_HIDDEN
    bnez t1, words_next # don't list hidden words
    li a0, CHAR_SPACE
    call out_put        # print a separating space first (emit's convention,
                        # also separates the list from the echoed command)
    lbu t0, CELL(a3)    # reload the flags+length byte (out_put clobbers t0)
    andi t0, t0, F_LENMASK
    addi a1, a3, CELL+1 # a1 = name start
    add a2, a1, t0      # a2 = name end
    call out_print      # print the name
words_next:
    lw a3, 0(a3)        # follow the link to the previous word
    j words_loop
words_done:
    NEXT

##
# Vocabularies (fig-Forth style)
#
# A vocabulary is a second, separate chain of words.  vocabulary edit  makes
# one; typing its name (edit) makes it the CONTEXT: the interpreter then looks
# a word up in edit first and in FORTH second.  definitions  makes the context
# the CURRENT vocabulary as well, the one new words are added to.  forth
# selects the main vocabulary again:
#     vocabulary edit
#     edit definitions   : k3 ... ;   forth definitions
# The same name can so mean different things in different vocabularies, which
# is what the phone uses for its modes (the same key does something else while
# dialling, in a call, in the editor). The key handler should not switch
# CONTEXT for that, since CONTEXT also decides what the console and the
# loaded lines find: keep the mode in a variable of its own and look bindings up
# with find-name-in.
# Any error puts CONTEXT and CURRENT back to FORTH (see reset).
##

# forth ( -- )          Make FORTH the context vocabulary
defcode "forth",5,,FORTH
    li t1, var_LATEST           # FORTH's head cell
    li t2, var_CONTEXT
    sw t1, 0(t2)
    NEXT

# definitions ( -- )    New words go to the context vocabulary from now on
defcode "definitions",11,,DEFINITIONS
    li t1, var_CONTEXT
    lw t1, 0(t1)
    li t2, var_CURRENT
    sw t1, 0(t2)
    NEXT

# context ( -- addr )   Variable: head cell of the vocabulary searched first
defcode "context",7,,CONTEXT
    li t1, var_CONTEXT
    PUSH t1
    NEXT

# current ( -- addr )   Variable: head cell of the vocabulary definitions go to
defcode "current",7,,CURRENT
    li t1, var_CURRENT
    PUSH t1
    NEXT

# voc-link ( -- addr )  Variable: the newest vocabulary (the address of its
# link cell, which follows its head cell), 0 if there is none. forget walks
# this list to trim every vocabulary.
defcode "voc-link",8,,VOCLINK
    li t1, var_VOCLINK
    PUSH t1
    NEXT

# >body ( cfa -- pfa )  From the code field of a CREATEd word to its first data
# cell (past the code field and the DOES> slot).  ' edit >body  is the head
# cell of the vocabulary edit, the value find-name-in takes.
defcode ">body",5,,TBODY
    checkunderflow 0
    lw t1, 0(s0)
    addi t1, t1, 2*CELL
    sw t1, 0(s0)
    NEXT

.balign CELL
# unlink from one vocabulary every word at or above an address
# arguments: a2 = head cell of the vocabulary, a1 = the address
# (within a chain the addresses fall from link to link, and flash is below RAM)
# clobbers: t0
trim_chain:
    lw t0, 0(a2)                # the newest word left in the chain
    bltu t0, a1, trim_done      # it is older (or the chain is empty: 0)
    lw t0, 0(t0)                # drop it: the word before it becomes the newest
    sw t0, 0(a2)
    j trim_chain
trim_done:
    ret

# forget ( "name" -- )  Remove a word and everything defined after it, in every
# vocabulary, and give the memory back. Vocabularies defined after it go too.
# Words in flash (below RAM_BASE) cannot be forgotten.
defcode "forget",6,,FORGET
    call token                  # a0 = token start, a1 = token length; TOIN moves past it
    beqz a1, err_error          # forget with no name
    call search_order           # a2 = header, or 0
    beqz a2, err_error          # no such word
    li t0, RAM_BASE
    bltu a2, t0, err_error      # a word in flash
    mv a1, a2                   # a1 = everything from here up goes
    li a2, var_LATEST
    call trim_chain             # FORTH
    li a3, var_VOCLINK          # a3 = the cell that points at the next vocabulary
forget_voc:
    lw a2, 0(a3)                # its link cell (0 = no more)
    beqz a2, forget_order
    bltu a2, a1, forget_keep
    lw t0, 0(a2)                # the vocabulary itself goes: take it off the list
    sw t0, 0(a3)
    j forget_voc
forget_keep:
    mv a3, a2                   # the list continues from its link cell
    addi a2, a2, -CELL          # its head cell sits just below
    call trim_chain
    j forget_voc
forget_order:
    # CONTEXT and CURRENT must not be left pointing into a forgotten vocabulary
    li t0, var_LATEST           # FORTH's head cell (it lies above the dictionary)
    li t1, var_CONTEXT
    lw t2, 0(t1)
    beq t2, t0, forget_current
    bltu t2, a1, forget_current
    sw t0, 0(t1)
forget_current:
    li t1, var_CURRENT
    lw t2, 0(t1)
    beq t2, t0, forget_here
    bltu t2, a1, forget_here
    sw t0, 0(t1)
forget_here:
    li t0, var_HERE
    sw a1, 0(t0)                # HERE = the header of the forgotten word
    NEXT

##
# Input and output
##

# CH32V006 PORT: key key? emit space cr type words use the I/O vectors
# (var_IN, var_OUT), set by <console <modem >console >modem and by reset.

# key ( -- x )          The next character from the input source (<console,
# <modem). The modem gives -1 if nothing came within mtimeout ms.
defcode "key",3,,KEY
    li t0, var_IN
    lw t0, 0(t0)        # the input table
    lw t0, 0(t0)        # its get routine
    jalr t0             # a0 = the character
    PUSH a0             # store character into top of data stack
    NEXT

# key? ( -- f )         True if the input source has a character waiting.
# The console's looks at the hardware only: while lines are loaded `key` is
# served from the flash instead, so do not call key or key? from
# loaded lines.
defcode "key?",4,,KEYQ
    li t0, var_IN
    lw t0, 0(t0)        # the input table
    lw t0, CELL(t0)     # its ready routine
    jalr t0             # a0 = 0 or -1
    PUSH a0
    NEXT

# emit ( x -- )         Send a character to the output (>console, >modem)
defcode "emit",4,,EMIT
    checkunderflow 0    # check for stack underflow of data stack (1 CELL)
    POP a0              # copy top of data stack into W
    call out_put        # send character from W through the output vector
    NEXT

# space ( -- )          Send one space
defcode "space",5,,SPACE
    li a0, CHAR_SPACE
    call out_put
    NEXT

# cr ( -- )             Send CR LF
defcode "cr",2,,CR
    li a0, CHAR_CARRIAGE
    call out_put
    li a0, CHAR_NEWLINE
    call out_put
    NEXT

# >console ( -- )       emit, type and the words built on them send to the console
defcode ">console",8,,TOCONSOLE
    la t1, uart_put
    li t0, var_OUT
    sw t1, 0(t0)
    NEXT

# <console ( -- )       key and key? read from the console
defcode "<console",8,,FROMCONSOLE
    la t1, in_console
    li t0, var_IN
    sw t1, 0(t0)
    NEXT

# bl ( -- 32 )          The space character
defcode "bl",2,,BL
    li t1, CHAR_SPACE
    PUSH t1
    NEXT

# base ( -- addr )      Number base of the output words (. u. #). Number
# input does not use it: see `number`.
defcode "base",4,,BASE
    li t1, var_BASE
    PUSH t1
    NEXT

# hld ( -- addr )       Pointer into the number being built by <# # #>
defcode "hld",3,,HLD
    li t1, var_HLD
    PUSH t1
    NEXT

##
# System
##

# tib ( -- addr )       Store TIB variable address in top of data stack
defcode "tib",3,,TIB
    li t1, TIB_BOTTOM   # load variable into temporary
    PUSH t1
    NEXT

# >in ( -- addr )       Store TOIN variable address in top of data stack
defcode ">in",3,,TOIN
    li t1, var_TOIN     # load variable into temporary
    PUSH t1
    NEXT

# abort ( -- )          Print "?" and restart: stacks cleared, interpret state
defcode "abort",5,,ABORT
    j err_error

# quit ( -- )           Empty the return stack, interpret state, fresh line;
# the data stack is left alone (ANS quit).
defcode "quit",4,,QUIT
    li tp, RSP_TOP
    li t0, var_STATE
    sw zero, 0(t0)
    j tib_init

# reboot ( -- )         # Reboot the entire system and initialize memory
defcode "reboot",6,,REBOOT
    j err_reboot        # jump to reboot
