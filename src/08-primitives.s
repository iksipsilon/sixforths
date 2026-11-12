##
# Forth primitives: every word written in machine code
#
# CH32V006 PORT: one file, sorted by what the words do (inner interpreter,
# data stack, return stack, memory, arithmetic, logic, comparison, strings and
# parsing, compiler and dictionary, input and output, system). It merges
# upstream's 08-forth-primitives.s with the port's eForth-style and ANS-style
# additions. The dictionary is chained in file order and searched from the
# end, so a word near the end of this file is found fastest. The log words
# (+log -log wipe) live with their machinery in 12-flash-log.s.
#
# Registers: sp = DSP (data stack), s0 = RSP (return stack), s1 = IP,
# a0 = W. These are the three "s" registers plus the first argument register:
# NEXT hands W to the code-field routine like an argument. Everything else is
# scratch inside a primitive: t0-t2, a1-a5, gp, tp. Prefer a1-a5 in new code
# (they allow 2-byte instructions where t0-t2, gp and tp do not).
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
    lw t1, 0(s0)                # biased index
    addi t2, t1, 1
    slt a1, t2, t1              # signed overflow of +1 <=> new < old
    bnez a1, xloop_done
    sw t2, 0(s0)
    lw s1, 0(s1)                # loop again: IP = target cell
    NEXT
xloop_done:
    addi s0, s0, 2*CELL         # drop the loop frame
    addi s1, s1, CELL           # skip the target cell
    NEXT

# xplusloop ( n -- ; R: sys sys -- | sys sys )   Step by n
# signed add overflow <=> (new < old) != (n < 0)
defcode "xplusloop",9,,XPLUSLOOP
    checkunderflow 0
    POP a2                      # n
    lw t1, 0(s0)                # biased index
    add t2, t1, a2
    slt a1, t2, t1
    slti a3, a2, 0
    xor a1, a1, a3
    bnez a1, xploop_done
    sw t2, 0(s0)
    lw s1, 0(s1)
    NEXT
xploop_done:
    addi s0, s0, 2*CELL
    addi s1, s1, CELL
    NEXT

# i ( -- n ; R: sys sys -- sys sys )   Innermost loop index
defcode "i",1,,IDX
    lw t1, 0(s0)
    lw t2, CELL(s0)
    sub t1, t1, t2
    PUSH t1
    NEXT

# j ( -- n )            Second loop index (the next loop out)
defcode "j",1,,JDX
    lw t1, 2*CELL(s0)
    lw t2, 3*CELL(s0)
    sub t1, t1, t2
    PUSH t1
    NEXT

# unloop ( -- ; R: sys sys -- )   Drop the loop frame (needed before exit)
defcode "unloop",6,,UNLOOP
    li t0, RSP_TOP-CELL         # need two cells on the return stack
    bge s0, t0, err_underflow
    addi s0, s0, 2*CELL
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
    li a0, var_LATEST
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
    addi sp, sp, CELL   # move the DSP up by 1 cell
    NEXT

# dup ( x -- x x )      Duplicate the top of the data stack
defcode "dup",3,,DUP
    checkunderflow 0    # need 1 item
    lw t1, 0(sp)        # load the top of the stack
    PUSH t1             # push a copy (PUSH clobbers t0)
    NEXT

# swap ( a b -- b a )   Exchange the top two items
defcode "swap",4,,SWAP
    checkunderflow CELL # need 2 items
    lw t1, 0(sp)        # b
    lw t2, CELL(sp)     # a
    sw t1, CELL(sp)
    sw t2, 0(sp)
    NEXT

# over ( a b -- a b a ) Push a copy of the second item
defcode "over",4,,OVER
    checkunderflow CELL # need 2 items
    lw t1, CELL(sp)     # a
    PUSH t1
    NEXT

# rot ( a b c -- b c a )
defcode "rot",3,,ROT
    checkunderflow 2*CELL
    lw t1, 0(sp)                # c
    lw t2, CELL(sp)             # b
    lw a1, 2*CELL(sp)           # a
    sw a1, 0(sp)
    sw t1, CELL(sp)
    sw t2, 2*CELL(sp)
    NEXT

# nip ( a b -- b )
defcode "nip",3,,NIP
    checkunderflow CELL
    lw t1, 0(sp)
    addi sp, sp, CELL
    sw t1, 0(sp)
    NEXT

# 2dup ( a b -- a b a b )
defcode "2dup",4,,TWODUP
    checkunderflow CELL
    lw t1, 0(sp)                # b
    lw t2, CELL(sp)             # a
    PUSH t2
    PUSH t1
    NEXT

# 2drop ( a b -- )
defcode "2drop",5,,TWODROP
    checkunderflow CELL
    addi sp, sp, 2*CELL
    NEXT

# ?dup ( x -- 0 | x x )
defcode "?dup",4,,QDUP
    checkunderflow 0
    lw t1, 0(sp)
    beqz t1, qdup_done
    PUSH t1
qdup_done:
    NEXT

# sp@ ( -- addr )       Get current data stack pointer (the address of the
# top cell before sp@ pushed its result)
defcode "sp@",3,,DSPFETCH
    mv t1, sp           # PUSH moves the DSP before it stores
    PUSH t1             # store DSP in the top of the stack
    NEXT

# sp! ( a -- )          Set the data stack pointer
defcode "sp!",3,,DSPSTORE
    checkunderflow 0    # need 1 item
    POP t1
    mv sp, t1
    NEXT

# s0 ( -- a )           Address just above the data stack's first cell
# depth is then:  : depth s0 sp@ - 2/ 2/ 1- ;
defcode "s0",2,,SZERO
    li t1, DSP_TOP
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
    bge s0, t0, err_underflow
    lw t1, 0(s0)
    PUSH t1
    NEXT

# rp@ ( -- addr )       Get current return stack pointer
defcode "rp@",3,,RSPFETCH
    PUSH s0             # store RSP in the top of the stack
    NEXT

# rp! ( a -- )          Set the return stack pointer
defcode "rp!",3,,RSPSTORE
    checkunderflow 0    # need 1 item
    POP t1
    mv s0, t1
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

# c@ ( a -- c )         Fetch one byte from address a
defcode "c@",2,,CFETCH
    checkunderflow 0    # need 1 item
    lw t1, 0(sp)        # load the address
    lbu t1, 0(t1)       # load the byte (any alignment is fine for lbu)
    sw t1, 0(sp)        # replace the top of the stack in place
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
    li a5, LOGBUF
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
    li a5, LOGBUF       # dictionary bounds check, like COLON's
    bge a4, a5, err_mem
    sw t1, 0(a4)        # store the cell
    addi a4, a4, CELL
    sw a4, 0(t2)        # advance HERE
    NEXT

##
# Arithmetic
##

# + ( x1 x2 -- n )      Add the two values at the top of the stack
defcode "+",1,,ADD
    checkunderflow CELL # check for stack underflow of data stack (2 CELLs)
    POP t0              # pop DSP value (x1) into temporary
    lw t1, 0(sp)        # load DSP value (x2) into temporary
    add t0, t0, t1      # add the two values
    sw t0, 0(sp)        # store the value into the top of the stack
    NEXT

# - ( a b -- a-b )      Subtraction
defcode "-",1,,SUB
    checkunderflow CELL # need 2 items
    POP t1              # b
    lw t2, 0(sp)        # a
    sub t2, t2, t1
    sw t2, 0(sp)
    NEXT

# * ( n1 n2 -- n3 )     Low 32 bits of the product (Zmmul `mul`)
defcode "*",1,,MUL
    checkunderflow CELL
    POP t1
    lw t2, 0(sp)
    mul t2, t2, t1
    sw t2, 0(sp)
    NEXT

# 1+ ( n -- n+1 )
defcode "1+",2,,ONEPLUS
    checkunderflow 0
    lw t1, 0(sp)
    addi t1, t1, 1
    sw t1, 0(sp)
    NEXT

# 1- ( n -- n-1 )
defcode "1-",2,,ONEMINUS
    checkunderflow 0
    lw t1, 0(sp)
    addi t1, t1, -1
    sw t1, 0(sp)
    NEXT

# 2* ( x -- x*2 )
defcode "2*",2,,TWOSTAR
    checkunderflow 0
    lw t1, 0(sp)
    slli t1, t1, 1
    sw t1, 0(sp)
    NEXT

# 2/ ( n -- n/2 )       Arithmetic shift: the sign is preserved
defcode "2/",2,,TWOSLASH
    checkunderflow 0
    lw t1, 0(sp)
    srai t1, t1, 1
    sw t1, 0(sp)
    NEXT

# negate ( n -- -n )
defcode "negate",6,,NEGATE
    checkunderflow 0
    lw t1, 0(sp)
    neg t1, t1
    sw t1, 0(sp)
    NEXT

# abs ( n -- |n| )
defcode "abs",3,,ABS
    checkunderflow 0
    lw t1, 0(sp)
    srai t2, t1, 31             # all ones if negative
    xor t1, t1, t2
    sub t1, t1, t2
    sw t1, 0(sp)
    NEXT

# min ( a b -- a|b )    Signed
defcode "min",3,,MIN
    checkunderflow CELL
    POP t1                      # b
    lw t2, 0(sp)                # a
    blt t2, t1, min_keep
    mv t2, t1
min_keep:
    sw t2, 0(sp)
    NEXT

# max ( a b -- a|b )    Signed
defcode "max",3,,MAX
    checkunderflow CELL
    POP t1                      # b
    lw t2, 0(sp)                # a
    blt t1, t2, max_keep
    mv t2, t1
max_keep:
    sw t2, 0(sp)
    NEXT

# cells ( n -- n*4 )
defcode "cells",5,,CELLS
    checkunderflow 0
    lw t1, 0(sp)
    slli t1, t1, 2
    sw t1, 0(sp)
    NEXT

# cell+ ( a -- a+4 )
defcode "cell+",5,,CELLPLUS
    checkunderflow 0
    lw t1, 0(sp)
    addi t1, t1, CELL
    sw t1, 0(sp)
    NEXT

# um+ ( u u -- sum carry ) Unsigned add with carry (eForth's arithmetic seed)
defcode "um+",3,,UMPLUS
    checkunderflow CELL # need 2 items
    lw t1, CELL(sp)     # first operand
    lw t2, 0(sp)        # second operand
    add a4, t1, t2      # 32-bit sum (wraps)
    sltu a5, a4, t1     # carry: unsigned sum < operand means it wrapped
    sw a4, CELL(sp)     # replace both cells in place
    sw a5, 0(sp)
    NEXT

# um* ( u1 u2 -- lo hi )   Unsigned 32x32 -> 64 multiply, hi on top.
# Built from four 16x16 `mul`s so it needs nothing beyond the base Zmmul `mul`
# (no mulhu): result = p00 + (p01+p10)<<16 + p11<<32, with the carries of the
# middle sum and of the low add folded into the high word.
defcode "um*",3,,UMSTAR
    checkunderflow CELL
    lw a1, 0(sp)                # b
    lw a2, CELL(sp)             # a
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
    sw t1, CELL(sp)             # lo (deeper)
    sw a4, 0(sp)                # hi (top)
    NEXT

# um/mod ( lo hi u -- rem quot )   Unsigned 64/32 division, 32-step restoring.
# Needs hi < u for a 32-bit quotient (otherwise the quotient wraps, as in
# every um/mod). u = 0 gives quot = -1 instead of trapping. The 33-bit case
# (remainder shifts a 1 out of bit 31) is handled explicitly, so divisors
# >= 2^31 work.   : u/mod 0 swap um/mod ;
defcode "um/mod",6,,UMDIVMOD
    checkunderflow 2*CELL
    lw a2, 0(sp)                # divisor
    lw t1, CELL(sp)             # hi -> becomes the remainder
    lw a1, 2*CELL(sp)           # lo -> becomes the quotient
    li t2, 32                   # bit counter
umdm_loop:
    srli a3, a1, 31             # next dividend bit
    srli a4, t1, 31             # bit about to fall out of the remainder
    slli a1, a1, 1              # bit 0 is now the quotient slot
    slli t1, t1, 1
    or t1, t1, a3
    bnez a4, umdm_sub           # 33-bit remainder is always >= divisor
    bltu t1, a2, umdm_next
umdm_sub:
    sub t1, t1, a2
    ori a1, a1, 1               # quotient bit = 1
umdm_next:
    addi t2, t2, -1
    bnez t2, umdm_loop
    addi sp, sp, CELL           # 3 in, 2 out
    sw t1, CELL(sp)             # remainder
    sw a1, 0(sp)                # quotient on top
    NEXT

# lshift ( x u -- x<<u )  The core uses the low 5 bits of u: u >= 32 wraps.
defcode "lshift",6,,LSHIFT
    checkunderflow CELL
    POP t1                      # u
    lw t2, 0(sp)                # x
    sll t2, t2, t1
    sw t2, 0(sp)
    NEXT

# rshift ( x u -- x>>u )  Logical shift. Same u >= 32 caveat as lshift.
defcode "rshift",6,,RSHIFT
    checkunderflow CELL
    POP t1                      # u
    lw t2, 0(sp)                # x
    srl t2, t2, t1
    sw t2, 0(sp)
    NEXT

##
# Logic
##

# and ( a b -- a&b )
defcode "and",3,,AND
    checkunderflow CELL # need 2 items
    POP t1
    lw t2, 0(sp)
    and t2, t2, t1
    sw t2, 0(sp)
    NEXT

# or ( a b -- a|b )
defcode "or",2,,OR
    checkunderflow CELL # need 2 items
    POP t1
    lw t2, 0(sp)
    or t2, t2, t1
    sw t2, 0(sp)
    NEXT

# xor ( a b -- a^b )
defcode "xor",3,,XOR
    checkunderflow CELL # need 2 items
    POP t1
    lw t2, 0(sp)
    xor t2, t2, t1
    sw t2, 0(sp)
    NEXT

# invert ( n -- ~n )    Bitwise complement (convenience; = -1 xor)
defcode "invert",6,,INVERT
    checkunderflow 0    # need 1 item
    lw t1, 0(sp)
    xori t1, t1, -1
    sw t1, 0(sp)
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

##
# Comparison (all return -1 / 0)
##

# 0= ( x -- f )         -1 if top of stack is 0, 0 otherwise
defcode "0=",2,,ZEQU
    checkunderflow 0    # check for stack underflow of data stack (1 CELL)
    lw t0, 0(sp)        # load the DSP value (x) into temporary
    snez t0, t0         # store 0 in temporary if it's equal to 0, otherwise store 1
    addi t0, t0, -1     # store -1 in temporary if it's 0, otherwise store 0
    sw t0, 0(sp)        # store value back into the top of the stack
    NEXT

# 0< ( n -- f )         True (-1) if n is negative, else 0 (eForth's only compare)
defcode "0<",2,,ZLESS
    checkunderflow 0    # need 1 item
    lw t1, 0(sp)
    srai t1, t1, 31     # arithmetic shift: sign bit fills the word
    sw t1, 0(sp)
    NEXT

# = ( a b -- f )
defcode "=",1,,EQUAL
    checkunderflow CELL
    POP t1
    lw t2, 0(sp)
    sub t2, t2, t1
    seqz t2, t2
    neg t2, t2
    sw t2, 0(sp)
    NEXT

# <> ( a b -- f )
defcode "<>",2,,NOTEQUAL
    checkunderflow CELL
    POP t1
    lw t2, 0(sp)
    sub t2, t2, t1
    snez t2, t2
    neg t2, t2
    sw t2, 0(sp)
    NEXT

# < ( a b -- f )       Signed
defcode "<",1,,LESS
    checkunderflow CELL
    POP t1                      # b
    lw t2, 0(sp)                # a
    slt t2, t2, t1
    neg t2, t2
    sw t2, 0(sp)
    NEXT

# > ( a b -- f )       Signed
defcode ">",1,,GREATER
    checkunderflow CELL
    POP t1
    lw t2, 0(sp)
    slt t2, t1, t2
    neg t2, t2
    sw t2, 0(sp)
    NEXT

# u< ( u1 u2 -- f )
defcode "u<",2,,ULESS
    checkunderflow CELL
    POP t1
    lw t2, 0(sp)
    sltu t2, t2, t1
    neg t2, t2
    sw t2, 0(sp)
    NEXT

# u> ( u1 u2 -- f )
defcode "u>",2,,UGREATER
    checkunderflow CELL
    POP t1
    lw t2, 0(sp)
    sltu t2, t1, t2
    neg t2, t2
    sw t2, 0(sp)
    NEXT

##
# Strings and parsing
##

# parse-name ( -- addr len )   Next space-delimited token from the TIB, advancing
# >in. len = 0 when the line is exhausted.
defcode "parse-name",10,,PARSENAME
    li t2, TIB_BOTTOM
    li a4, var_TOIN
    lw a0, 0(a4)
    add a0, a0, t2              # a0 = parse position in the TIB
    call token                  # a0 = token start, a1 = token length
    li t2, TIB_BOTTOM
    add t0, a0, a1
    sub t0, t0, t2
    sw t0, 0(a4)                # TOIN moves past the token
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

# find-name ( addr len -- header | 0 )   Dictionary search. Unlike the
# interpreter's own lookup, a miss returns 0 instead of aborting. Hidden words
# are skipped. The result is a header address: feed it to >cfa for the xt, or
# read the flags with  4 + c@  (bit 7 = immediate).
defcode "find-name",9,,FINDNAME
    checkunderflow CELL
    POP a1                      # length
    POP a0                      # name address
    li t2, var_LATEST
    lw t2, 0(t2)                # t2 = cursor in the dictionary chain
fn_loop:
    beqz t2, fn_found           # end of chain: t2 = 0 is the "not found" answer
    lbu t0, CELL(t2)            # flags + length
    andi t1, t0, F_HIDDEN
    bnez t1, fn_next
    andi t0, t0, F_LENMASK
    bne t0, a1, fn_next
    addi a4, t2, CELL+1         # name in the header
    mv a5, a0                   # name being looked up
    mv t1, t0                   # compare t0 bytes
fn_cmp:
    beqz t1, fn_found
    lbu t0, 0(a4)
    lbu a3, 0(a5)
    bne t0, a3, fn_next
    addi a4, a4, 1
    addi a5, a5, 1
    addi t1, t1, -1
    j fn_cmp
fn_next:
    lw t2, 0(t2)
    j fn_loop
fn_found:
    PUSH t2
    NEXT

##
# Compiler and dictionary
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
    # code field: docol, the same value a defword header holds
    # (CH32V006 PORT: upstream pointed it at a `j docol` stub, one extra
    # jump for every call of a colon word)
    la a2, docol        # load the codeword address into Y working register
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

# create ( "name" -- )  Build a header at HERE; the word pushes its pfa (the
# first data cell, after the code field and the DOES> slot) when executed.
#   : variable create 0 , ;
#   : constant create , docon latest @ >cfa ! ;
defcode "create",6,,CREATE
    li t2, TIB_BOTTOM
    li a4, var_TOIN
    lw a0, 0(a4)
    add a0, a0, t2
    call token                  # a0 = token start, a1 = token length
    li t2, TIB_BOTTOM
    add t0, a0, a1
    sub t0, t0, t2
    sw t0, 0(a4)                # TOIN moves past the token
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
    li t1, var_LATEST
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
    li t2, TIB_BOTTOM
    li a4, var_TOIN
    lw a0, 0(a4)
    add a0, a0, t2      # a0 = current parse position in the TIB
    call token          # a0 = token start, a1 = token length
    li t2, TIB_BOTTOM   # update TOIN past the consumed token
    add t0, a0, a1
    sub t0, t0, t2
    sw t0, 0(a4)
    beqz a1, err_error  # ' with nothing after it
    li a2, var_LATEST   # lookup by name: a0 = token address, a1 = length
    lw a2, 0(a2)
    call lookup         # a1 = word header address (lookup errors out if not found)
    mv a0, a1
    call to_cfa         # a0 = code field address
    # state-smart: push when executing, compile a literal when compiling
    li t1, var_STATE
    lw t1, 0(t1)
    beqz t1, tick_push
    la t1, LIT          # compile: LIT codeword cell, then the cfa cell
    li t2, var_HERE
    lw a4, 0(t2)
    li a5, LOGBUF-CELL  # need room for two cells
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
    lw a0, 0(sp)        # load the header address from the top of the stack
    call to_cfa         # a0 = code field address (clobbers t0, ra)
    sw a0, 0(sp)        # store it back on the stack
    NEXT

# latest ( -- addr )     Store LATEST variable address in top of data stack
defcode "latest",6,,LATEST
    li t1, var_LATEST   # load variable into temporary
    PUSH t1
    NEXT

# state ( -- addr )     Store STATE variable address in top of data stack
defcode "state",5,,STATE
    li t1, var_STATE    # load variable into temporary
    PUSH t1
    NEXT

# words ( -- )          List the names of all visible words in the dictionary,
# newest first. This is the payoff of storing names instead of hashes.
defcode "words",5,,WORDS
    li a3, var_LATEST   # a3 (Z) survives uart_print/uart_put (they clobber
    lw a3, 0(a3)        # only a0-a2, t0, t1, ra) so it holds the chain pointer
words_loop:
    beqz a3, words_done # end of the dictionary: link is 0
    lbu t0, CELL(a3)    # load the flags+length byte
    andi t1, t0, F_HIDDEN
    bnez t1, words_next # don't list hidden words
    li a0, CHAR_SPACE
    call uart_put       # print a separating space first (emit's convention,
                        # also separates the list from the echoed command)
    lbu t0, CELL(a3)    # reload the flags+length byte (uart_put clobbers t0)
    andi t0, t0, F_LENMASK
    addi a1, a3, CELL+1 # a1 = name start
    add a2, a1, t0      # a2 = name end
    call uart_print     # print the name
words_next:
    lw a3, 0(a3)        # follow the link to the previous word
    j words_loop
words_done:
    NEXT

##
# Input and output
##

# key ( -- x )          Read 8-bit character from uart input
defcode "key",3,,KEY
    call uart_get       # read character from uart into W
    PUSH a0             # store character into top of data stack
    NEXT

# key? ( -- f )         True if the console UART has a character waiting.
# Looks at the hardware only: during the boot replay `key` is served from
# the flash log instead, so do not call key or key? from replayed lines.
defcode "key?",4,,KEYQ
    li t0, UART_BASE_ADDRESS
    lw t1, UART_RX_STATUS(t0)
    andi t1, t1, UART_RX_BIT
    snez t1, t1
    neg t1, t1
    PUSH t1                     # (clobbers t0, already consumed)
    NEXT

# emit ( x -- )         Write 8-bit character to uart output
defcode "emit",4,,EMIT
    checkunderflow 0    # check for stack underflow of data stack (1 CELL)
    POP a0              # copy top of data stack into W
    call uart_put       # send character from W to uart
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
    li s0, RSP_TOP
    li t0, var_STATE
    sw zero, 0(t0)
    j tib_init

# reboot ( -- )         # Reboot the entire system and initialize memory
defcode "reboot",6,,REBOOT
    j err_reboot        # jump to reboot
