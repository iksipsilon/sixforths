##
# ANS-flavoured kernel primitives (CH32V006 port, commit 13)
#
# Adds the words that cannot sensibly be built in Forth from 08/11/12 alone
# (shifts, comparisons, multiply/divide, block moves, loop runtime, string
# literals) plus the hooks that let Forth reach the interpreter internals
# (parse-name, parse, find-name, number, create, dovar, docon, docol, xdoes).
#
# Conventions, same as 11-eforth-primitives.s:
#   sp = DSP, s0 = RSP, s1 = IP, a0 = W. Primitives may clobber every other
#   register: the interpreter reloads its loop state on every pass through
#   process_token. t0 is clobbered by PUSH, PUSHRSP, POPRSP and checkunderflow.
#   checkunderflow N*CELL guards N+1 items (checkunderflow 0 guards 1 item).
#   Flags are -1 (true) / 0 (false), ANS style, like 0= and 0<.
#   lw/sw on the QingKe V2 trap when misaligned, so +! needs an aligned
#   address, exactly like @ and !.
#
# NAMING: no word name may contain '(' or '\' -- the REPL's character loop in
# 09-interpreter.s swallows those as comment starters before they reach the
# TIB, so a word called (loop) could be defined but never typed. The loop
# runtime words are therefore called xdo, xloop and xplusloop.
##

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
# Arithmetic and shifts
##

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

# negate ( n -- -n )
defcode "negate",6,,NEGATE
    checkunderflow 0
    lw t1, 0(sp)
    neg t1, t1
    sw t1, 0(sp)
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

# * ( n1 n2 -- n3 )     Low 32 bits of the product (Zmmul `mul`)
defcode "*",1,,MUL
    checkunderflow CELL
    POP t1
    lw t2, 0(sp)
    mul t2, t2, t1
    sw t2, 0(sp)
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

##
# Comparisons (all return -1 / 0)
##

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
# Memory
##

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

##
# Stack
##

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

# s0 ( -- a )           Address just above the data stack's first cell
# depth is then:  : depth s0 sp@ - 2/ 2/ 1- ;
defcode "s0",2,,SZERO
    li t1, DSP_TOP
    PUSH t1
    NEXT

# r0 ( -- a )           Address just above the return stack's first cell
defcode "r0",2,,RZERO
    li t1, RSP_TOP
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

##
# Input
##

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

##
# DO ... LOOP runtime
#
# Return stack frame (top first):  index+fudge, fudge   where
# fudge = 0x80000000 - limit. The loop ends exactly when the signed add that
# steps the biased index overflows, i.e. when the index crosses the boundary
# between limit-1 and limit, in either direction (ANS semantics; Rodriguez's
# trick, borrowed from F83). i recovers the true index as biased - fudge.
#
# Compile with absolute targets, like branch/0branch:
#   : do      ' xdo , here @ ; immediate
#   : loop    ' xloop , , ; immediate
#   : +loop   ' xplusloop , , ; immediate
##

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

##
# Reaching the interpreter from Forth
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

# ['] ( "name" -- cfa )   Immediate alias of the state-smart ': inside a colon
# definition it compiles the next word's code field address as a literal.
defcode "[']",3,F_IMMEDIATE,BTICK
    j code_TICK

##
# Leaving the interpreter
##

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
