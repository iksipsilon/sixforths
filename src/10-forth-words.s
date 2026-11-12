##
# Forth words: colon definitions that live in flash (CH32V006 port)
#
# These are the words of the former prelude.f. They used to be typed (or
# replayed from the log) into RAM at every boot, where they took about 2.8 KB
# of the 6.9 KB dictionary. Here each one is the same thread the compiler
# would build, written out by hand with defword: a list of code field
# addresses, 4 bytes per word called. The Forth source is the comment above
# each thread.
#
# How to read and write a thread:
#   - A word is named by its assembly label (see 08-primitives.s): dup is DUP,
#     @ is FETCH, 0branch is ZBRANCH, and so on.
#   - A number in the source becomes  LIT, <number>.
#   - Control flow is spelled out with the two branch words. Their targets
#     are absolute addresses, so local labels do the work:
#       if ... then            ZBRANCH, 1f, ...          1:
#       if ... else ... then   ZBRANCH, 1f, ..., BRANCH, 2f   1: ...   2:
#       begin ... until        1: ..., ZBRANCH, 1b
#       begin ... while ... repeat   1: ..., ZBRANCH, 2f, ..., BRANCH, 1b   2:
#       do ... loop            XDO   1: ..., XLOOP, 1b
#     (labels 8 and 9 are taken by the header macro: use 1 to 7)
#   - A compiling word (immediate) lays cells down at run time with COMMA;
#     LIT, ZBRANCH, COMMA  compiles a 0branch into the word being defined.
#   - Every thread ends with EXIT.
#   - A variable cannot live here: flash is read-only. Give it a RAM cell
#     (var_X in 01-variables-constants.s) and a defcode that pushes its
#     address, like base and hld.
#
# Whether a word belongs here or in 08-primitives.s: byte loops and anything
# that mostly shuffles the stack are shorter and much faster in machine code
# (type is 32 bytes there, 64 as a thread); words that mostly call other
# words are shorter and easier to get right as threads.
##

##
# Control flow (all immediate: they run while a definition is compiled)
##

# : begin here @ ; immediate
defword "begin",5,F_IMMEDIATE,BEGIN
    .int HERE, FETCH, EXIT

# : until ' 0branch , , ; immediate
defword "until",5,F_IMMEDIATE,UNTIL
    .int LIT, ZBRANCH, COMMA, COMMA, EXIT

# : again ' branch , , ; immediate
defword "again",5,F_IMMEDIATE,AGAIN
    .int LIT, BRANCH, COMMA, COMMA, EXIT

# : if ' 0branch , here @ 0 , ; immediate
defword "if",2,F_IMMEDIATE,IF
    .int LIT, ZBRANCH, COMMA, HERE, FETCH, LIT, 0, COMMA, EXIT

# : then here @ swap ! ; immediate
defword "then",4,F_IMMEDIATE,THEN
    .int HERE, FETCH, SWAP, STORE, EXIT

# : else ' branch , here @ 0 , swap here @ swap ! ; immediate
defword "else",4,F_IMMEDIATE,ELSE
    .int LIT, BRANCH, COMMA, HERE, FETCH, LIT, 0, COMMA
    .int SWAP, HERE, FETCH, SWAP, STORE, EXIT

# : while ' 0branch , here @ 0 , swap ; immediate
defword "while",5,F_IMMEDIATE,WHILE
    .int LIT, ZBRANCH, COMMA, HERE, FETCH, LIT, 0, COMMA, SWAP, EXIT

# : repeat ' branch , , here @ swap ! ; immediate
defword "repeat",6,F_IMMEDIATE,REPEAT
    .int LIT, BRANCH, COMMA, COMMA, HERE, FETCH, SWAP, STORE, EXIT

# : do ' xdo , here @ ; immediate
defword "do",2,F_IMMEDIATE,DO
    .int LIT, XDO, COMMA, HERE, FETCH, EXIT

# : loop ' xloop , , ; immediate
defword "loop",4,F_IMMEDIATE,LOOP
    .int LIT, XLOOP, COMMA, COMMA, EXIT

# : +loop ' xplusloop , , ; immediate
defword "+loop",5,F_IMMEDIATE,PLUSLOOP
    .int LIT, XPLUSLOOP, COMMA, COMMA, EXIT

##
# Compiling and defining words
##

# : literal ' lit , , ; immediate
defword "literal",7,F_IMMEDIATE,LITERAL
    .int LIT, LIT, COMMA, COMMA, EXIT

# : recurse latest @ >cfa , ; immediate
defword "recurse",7,F_IMMEDIATE,RECURSE
    .int LATEST, FETCH, TCFA, COMMA, EXIT

# : variable create 0 , ;
defword "variable",8,,VARIABLE
    .int CREATE, LIT, 0, COMMA, EXIT

# : constant create , docon latest @ >cfa ! ;
defword "constant",8,,CONSTANT
    .int CREATE, COMMA, DOCONW, LATEST, FETCH, TCFA, STORE, EXIT

# : does> ' xdoes , ; immediate
defword "does>",5,F_IMMEDIATE,DOES
    .int LIT, XDOES, COMMA, EXIT

##
# Number output
##

# : decimal 10 base ! ;
defword "decimal",7,,DECIMAL
    .int LIT, 10, BASE, STORE, EXIT

# : hex 16 base ! ;
defword "hex",3,,HEX
    .int LIT, 16, BASE, STORE, EXIT

# : spaces begin dup 0> while space 1- repeat drop ;
defword "spaces",6,,SPACES
1:  .int DUP, ZGREATER, ZBRANCH, 2f
    .int SPACE, ONEMINUS, BRANCH, 1b
2:  .int DROP, EXIT

# : <# pad 128 + hld ! ;
# The number is built downwards from the middle of PAD.
defword "<#",2,,BRASHARP
    .int PADADDR, LIT, 128, ADD, HLD, STORE, EXIT

# : hold hld @ 1- dup hld ! c! ;
defword "hold",4,,HOLD
    .int HLD, FETCH, ONEMINUS, DUP, HLD, STORE, CSTORE, EXIT

# : digit dup 9 > if 7 + then 48 + ;
defword "digit",5,,DIGIT
    .int DUP, LIT, 9, GREATER, ZBRANCH, 1f
    .int LIT, 7, ADD
1:  .int LIT, 48, ADD, EXIT

# : ud/mod >r 0 r@ um/mod r> swap >r um/mod r> ;
# ( ud u -- rem udquot )  double divided by single, double quotient
defword "ud/mod",6,,UDDIVMOD
    .int TOR, LIT, 0, RFETCH, UMDIVMOD, FROMR, SWAP, TOR, UMDIVMOD, FROMR, EXIT

# : # base @ ud/mod rot digit hold ;
defword "#",1,,SHARP
    .int BASE, FETCH, UDDIVMOD, ROT, DIGIT, HOLD, EXIT

# : #s begin # 2dup or 0= until ;
defword "#s",2,,SHARPS
1:  .int SHARP, TWODUP, OR, ZEQU, ZBRANCH, 1b
    .int EXIT

# : #> 2drop hld @ pad 128 + over - ;
defword "#>",2,,SHARPKET
    .int TWODROP, HLD, FETCH, PADADDR, LIT, 128, ADD, OVER, SUB, EXIT

# : sign 0< if 45 hold then ;
defword "sign",4,,SIGN
    .int ZLESS, ZBRANCH, 1f
    .int LIT, 45, HOLD
1:  .int EXIT

# : u. 0 <# #s #> type space ;
defword "u.",2,,UDOT
    .int LIT, 0, BRASHARP, SHARPS, SHARPKET, TYPE, SPACE, EXIT

# : . dup abs 0 <# #s rot sign #> type space ;
defword ".",1,,DOT
    .int DUP, ABS, LIT, 0, BRASHARP, SHARPS, ROT, SIGN, SHARPKET, TYPE, SPACE, EXIT

##
# Strings
##

# : s, dup , here @ swap dup allot cmove align ;
# ( addr len -- )  lay a string down at HERE: length cell, bytes, padding
defword "s,",2,,SCOMMA
    .int DUP, COMMA, HERE, FETCH, SWAP, DUP, ALLOT, CMOVE, ALIGN, EXIT

# : s" 34 parse ' litstring , s, ; immediate
defword "s\"",2,F_IMMEDIATE,SQUOTE
    .int LIT, 34, PARSE, LIT, LITSTRING, COMMA, SCOMMA, EXIT

# : ." 34 parse ' litstring , s, ' type , ; immediate
defword ".\"",2,F_IMMEDIATE,DOTQUOTE
    .int LIT, 34, PARSE, LIT, LITSTRING, COMMA, SCOMMA, LIT, TYPE, COMMA, EXIT

##
# Dictionary
##

# : find dup count find-name ?dup
#     if nip dup >cfa swap 4 + c@ 128 and if 1 else -1 then else 0 then ;
# ( c-addr -- c-addr 0 | xt 1 | xt -1 )  the classic FIND on a counted string
defword "find",4,,FIND
    .int DUP, COUNT, FINDNAME, QDUP, ZBRANCH, 3f
    .int NIP, DUP, TCFA, SWAP, LIT, 4, ADD, CFETCH, LIT, 128, AND, ZBRANCH, 1f
    .int LIT, 1, BRANCH, 2f
1:  .int LIT, -1
2:  .int BRANCH, 4f
3:  .int LIT, 0
4:  .int EXIT

# : vocabulary create 0 , here @ voc-link @ , voc-link ! dovoc latest @ >cfa ! ;
# A vocabulary's data: its head cell (0: empty), then the link to the
# vocabulary made before it. Its code field is dovoc_code.
defword "vocabulary",10,,VOCABULARY
    .int CREATE, LIT, 0, COMMA
    .int HERE, FETCH, VOCLINK, FETCH, COMMA, VOCLINK, STORE
    .int DOVOCW, LATEST, FETCH, TCFA, STORE, EXIT

##
# Debugging
##

# : .s depth ?dup if 0 do s0 i 1+ cells - @ . loop then ;
defword ".s",2,,DOTS
    .int DEPTH, QDUP, ZBRANCH, 2f
    .int LIT, 0, XDO
1:  .int SZERO, IDX, ONEPLUS, CELLS, SUB, FETCH, DOT, XLOOP, 1b
2:  .int EXIT

# : nib 15 and digit emit ;
defword "nib",3,,NIB
    .int LIT, 15, AND, DIGIT, EMIT, EXIT

# : b. dup 4 rshift nib nib space ;
defword "b.",2,,BDOT
    .int DUP, LIT, 4, RSHIFT, NIB, NIB, SPACE, EXIT

# : w. 28 begin 2dup rshift nib 4 - dup 0< until 2drop space ;
defword "w.",2,,WDOT
    .int LIT, 28
1:  .int TWODUP, RSHIFT, NIB, LIT, 4, SUB, DUP, ZLESS, ZBRANCH, 1b
    .int TWODROP, SPACE, EXIT

# : dump ?dup if 0 do i 15 and 0= if cr dup i + w. then dup i + c@ b. loop then drop ;
# ( addr u -- )  hex dump, 16 bytes to a line
defword "dump",4,,DUMP
    .int QDUP, ZBRANCH, 3f
    .int LIT, 0, XDO
1:  .int IDX, LIT, 15, AND, ZEQU, ZBRANCH, 2f
    .int CR, DUP, IDX, ADD, WDOT
2:  .int DUP, IDX, ADD, CFETCH, BDOT, XLOOP, 1b
3:  .int DROP, EXIT

# back to code: the files included after this one start with machine code
.text
