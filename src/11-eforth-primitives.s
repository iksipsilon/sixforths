##
# eForth-style kernel primitives
#
# Extends the base 19 FiveForths primitives toward the canonical eForth
# machine-word set (Ting/Muench, ~31 kernel words), from which everything
# else can be written in Forth itself. Naming and layout follow the
# conventions of 08-forth-primitives.s. Headers are jonesforth-style counted strings.
#
# Register conventions (CH32V006 port): sp=DSP, s0=RSP, s1=IP,
# scratch: t0 (clobbered by PUSH/POP*/checkunderflow macros!), t1, t2, a4, a5.
# QingKe V2 alignment rules: cell accesses (lw/sw) here touch only the data
# stack, return stack, and dictionary cells -- all CELL-aligned by
# construction. Byte accesses (lbu/sb in c@/c!) are alignment-free.
##

##
# Data stack manipulation
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

# sp! ( a -- )          Set the data stack pointer
defcode "sp!",3,,DSPSTORE
    checkunderflow 0    # need 1 item
    POP t1
    mv sp, t1
    NEXT

# rp! ( a -- )          Set the return stack pointer
defcode "rp!",3,,RSPSTORE
    checkunderflow 0    # need 1 item
    POP t1
    mv s0, t1
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

##
# Byte memory access (alignment-free on QingKe V2)
##

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

# 0< ( n -- f )         True (-1) if n is negative, else 0 (eForth's only compare)
defcode "0<",2,,ZLESS
    checkunderflow 0    # need 1 item
    lw t1, 0(sp)
    srai t1, t1, 31     # arithmetic shift: sign bit fills the word
    sw t1, 0(sp)
    NEXT

##
# Arithmetic
##

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

# - ( a b -- a-b )      Subtraction
defcode "-",1,,SUB
    checkunderflow CELL # need 2 items
    POP t1              # b
    lw t2, 0(sp)        # a
    sub t2, t2, t1
    sw t2, 0(sp)
    NEXT

##
# Inner interpreter words (control flow and compiling)
##

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

# , ( x -- )            Append a cell to the dictionary at HERE
defcode ",",1,,COMMA
    checkunderflow 0    # need 1 item
    POP t1
    li t2, var_HERE
    lw a4, 0(t2)        # current HERE value
    li a5, LOGBUF       # dictionary bounds check, like COLON's
    bge a4, a5, err_mem
    sw t1, 0(a4)        # store the cell
    addi a4, a4, CELL
    sw a4, 0(t2)        # advance HERE
    NEXT

##
# Defining words (CH32V006 port, commit 9)
##

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

# >cfa ( wa -- cfa )    Convert a word header address (e.g. latest @) to its
# code field address, skipping the link, the flags+length byte, the name,
# and the alignment padding (jonesforth >CFA).
defcode ">cfa",4,,TCFA
    checkunderflow 0    # need 1 item
    lw a0, 0(sp)        # load the header address from the top of the stack
    call to_cfa         # a0 = code field address (clobbers t0, ra)
    sw a0, 0(sp)        # store it back on the stack
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
