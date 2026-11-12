##
# Macros
##

# jump to the next subroutine (ITC), appended to each primitive
.macro NEXT
    lw a0, 0(s1)        # load memory address from IP into W
    addi s1, s1, CELL   # increment IP by CELL size
    lw t0, 0(a0)        # load address from W into temporary
    jr t0               # jump to the address in temporary
.endm

# pop top of data stack to register and move DSP
.macro POP reg
    lw \reg, 0(sp)      # load DSP value to register
    addi sp, sp, CELL   # move the DSP up by 1 cell
.endm

# push register to top of stack and move DSP
# CH32V006 PORT: the DSP moves first, then the store. sp is the data stack,
# and the QingKe V2 stacks its interrupt frame at sp (hardware prologue, 48
# bytes, processor manual 3.4): a cell stored below sp before sp moved could
# be overwritten by an interrupt arriving between the two instructions.
# IRQ_FRAME bytes stay free under the deepest cell for that frame. (The new
# order is also 2 bytes shorter: a negative offset cannot be compressed.)
# Do not PUSH sp itself: copy it to a register first (see sp@).
.macro PUSH reg
    li t0, RSP_TOP+CELL+IRQ_FRAME   # lowest DSP that still has room for a cell
    blt sp, t0, err_overflow    # jump to error handler if stack overflow

    addi sp, sp, -CELL  # move the DSP down by 1 cell
    sw \reg, 0(sp)      # store the value in the register to the top of the DSP
.endm

# push register to return stack
.macro PUSHRSP reg
    li t0, TIB_TOP+CELL         # load address of bottom of stack + 1 CELL
    blt s0, t0, err_overflow    # jump to error handler if stack overflow

    addi s0, s0, -CELL  # decrement RSP by 1 cell
    sw \reg, 0(s0)      # store value from register into RSP
.endm

# pop top of return stack to register
.macro POPRSP reg
    li t0, RSP_TOP              # load address of top of RSP
    bge s0, t0, err_underflow   # jump to error handler if stack underflow

    lw \reg, 0(s0)      # load value from RSP into register
    addi s0, s0, CELL   # increment RSP by 1 cell
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

# print a message
.macro print_error name, size, jump
    .balign CELL
  err_\name :
    la a1, msg_\name    # load string message
    addi a2, a1, \size  # load string length
    call uart_print     # call uart print function
    j \jump             # jump when print returns
.endm

# restore HERE and LATEST variables
.macro restorevars reg
    # update HERE
    li t0, var_HERE     # load HERE variable into temporary
    sw \reg, 0(t0)      # store the address of LATEST back into HERE

    # update LATEST
    li t0, var_LATEST   # load LATEST variable into temporary
    lw t1, 0(\reg)      # load LATEST variable value into temporary
    sw t1, 0(t0)        # store LATEST word into LATEST variable
.endm

# check for stack underflow
.macro checkunderflow stacktop
    li t0, DSP_TOP-\stacktop    # load address of top of stack
    bge sp, t0, err_underflow   # jump to error handler if stack underflow
.endm
