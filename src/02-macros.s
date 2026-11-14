##
# Macros
##

# jump to the next subroutine (ITC), appended to each primitive
# CH32V006 PORT: the temporary is a5, not t0. The 2-byte forms of lw/sw
# through a pointer only take s0, s1 and a0-a5 (both registers), so with
# IP = s1, W = a0 and a5 all four instructions are compressed: 8 bytes instead of 10 for every
# NEXT. Nothing is live in a5 when a word ends.
.macro NEXT
    lw a0, 0(s1)        # load memory address from IP into W
    addi s1, s1, CELL   # increment IP by CELL size
    lw a5, 0(a0)        # load address from W into temporary
    jr a5               # jump to the address in temporary
.endm

# pop top of data stack to register and move DSP
.macro POP reg
    lw \reg, 0(s0)      # load DSP value to register
    addi s0, s0, CELL   # move the DSP up by 1 cell
.endm

# push register to top of stack and move DSP
# CH32V006 PORT: the DSP moves first, then the store (2 bytes shorter: a
# negative offset cannot be compressed). So do not PUSH s0 itself: copy it to
# a register first (see sp@).
.macro PUSH reg
    li t0, RSP_TOP+CELL         # load address of bottom of stack + 1 CELL
    blt s0, t0, err_overflow    # jump to error handler if stack overflow

    addi s0, s0, -CELL  # move the DSP down by 1 cell
    sw \reg, 0(s0)      # store the value in the register to the top of the DSP
.endm

# push register to return stack
.macro PUSHRSP reg
    li t0, TIB_TOP+CELL         # load address of bottom of stack + 1 CELL
    blt tp, t0, err_overflow    # jump to error handler if stack overflow

    addi tp, tp, -CELL  # decrement RSP by 1 cell
    sw \reg, 0(tp)      # store value from register into RSP
.endm

# pop top of return stack to register
.macro POPRSP reg
    li t0, RSP_TOP              # load address of top of RSP
    bge tp, t0, err_underflow   # jump to error handler if stack underflow

    lw \reg, 0(tp)      # load value from RSP into register
    addi tp, tp, CELL   # increment RSP by 1 cell
.endm

# Dictionary words, as in jonesforth
# CH32V006 PORT: upstream hashed the name and took the previous word's label
# as an argument. Now:
#   defcode name, namelen, flags=0, label    a word written in assembly
#   defword name, namelen, flags=0, label    a colon word written as a thread
# e.g.  defcode "1+",2,,ONEPLUS              defword "2+",2,,TWOPLUS
#           ... machine code ... NEXT            .int ONEPLUS, ONEPLUS, EXIT
# Labels: name_X = header, X = codeword (what a thread lists), code_X =
# machine code of a defcode word. Header: link cell, flags+length byte, name,
# zero padding to a CELL boundary, then the codeword. Headers and codewords
# go to .rodata, machine code to .text. `link` chains the headers in assembly
# order (0 ends the chain; sixforths.s saves the last one as last_word). The
# build stops if namelen does not match the name. RISC-V note: jonesforth's
# `.align 4` would mean 16 bytes here, hence .balign CELL.
.set link, 0

# header shared by defcode and defword
.macro defheader name, namelen, flags, label
    .section .rodata
    .balign CELL                # headers start on a CELL boundary
    .globl name_\label
name_\label :
    .equ .Lprev_\@, link        # snapshot of link: the RISC-V assembler
                                # refuses a reloc against a redefined symbol
    .4byte .Lprev_\@            # link: header of the previous word
    .set link, name_\label
    .byte \flags + \namelen     # flags+length byte
8:  .ascii "\name"              # the name (GAS strips the call site's quotes)
9:  .if (9b - 8b) - \namelen
    .error "namelen of \label does not match its name"
    .endif
    .balign CELL, 0             # pad the name with zeros to a CELL boundary
    .globl \label
\label :                        # the codeword follows
.endm

.macro defcode name, namelen, flags=0, label
    defheader "\name", \namelen, \flags, \label
    .4byte code_\label          # codeword: address of the machine code
    .text
    .globl code_\label
code_\label :                   # machine code follows, ending with NEXT
.endm

# defword leaves .rodata active for the thread; put .text before any plain
# code that follows it.
.macro defword name, namelen, flags=0, label
    defheader "\name", \namelen, \flags, \label
    .4byte docol                # codeword: the colon-definition interpreter
.endm

# check a character
.macro checkchar char, dest
    call uart_get       # read a character from UART
    call uart_put       # send the character to UART

    # validate the character which is located in the W (a0) register
    li t0, \char        # load character into temporary
    beq a0, t0, \dest   # jump to the destination if the char matches
.endm

# a message for the console: msg_X is its start, end_X its end
# CH32V006 PORT: the lengths were counted by hand at each use; now a label
# marks the end. (A length computed as end - start does not always assemble:
# the RISC-V assembler leaves some label differences to the linker.)
.macro message name, text
  msg_\name : .ascii "\text"
  end_\name :
.endm

# print a message on the console
# clobbers: a0, a1, a2, t0, t1, ra
.macro print_message name
    la a1, msg_\name            # load string message
    la a2, end_\name            # its end
    call uart_print             # call uart print function
.endm

# an error handler: print a message, then jump
.macro print_error name, jump
    .balign CELL
  err_\name :
    print_message \name
    j \jump             # jump when print returns
.endm

# check for stack underflow
.macro checkunderflow stacktop
    li t0, DSP_TOP-\stacktop    # load address of top of stack
    bge s0, t0, err_underflow   # jump to error handler if stack underflow
.endm
