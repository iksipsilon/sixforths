##
# sixforths: an indirect-threaded Forth for the CH32V006 (the top-level file)
# Derived from FiveForths (MIT licence, see LICENSE)
##

##
# Registers
##

# The QingKe V2C core is RV32EC: only x0..x15 exist (no s2-s11, no t3-t6).
# gp and tp are free for the kernel: no C runtime, no .sdata relaxation, no
# threads.
#
# The Forth registers:
# s0 = DSP = data stack pointer (the FP convention serves no purpose here:
#            no stack frames, no C interop, no unwinder)
# tp = RSP = return stack pointer
# s1 = IP  = instruction pointer
# a0 = W   = working register (NEXT hands it to the code-field routine)
# s0, tp and s1 are the registers no subroutine and no interrupt touches.
# With IP = s1 and W = a0, every instruction of NEXT has a 2-byte form.
#
# sp = the machine stack: interrupt frames and the return addresses of nested
#      subroutines (01-variables-constants.s, MSTACK_SIZE). On the QingKe V2
#      an interrupt stores its frame at sp (hardware prologue, HPE), so sp is
#      left to the machine and the data stack has s0.
#
# Scratch inside a primitive:
# a1 = X, a2 = Y, a3 = Z = working registers
# a4 = scratch
# a5 = scratch; NEXT uses it as its temporary
# t0 = temporary of the PUSH, PUSHRSP, POPRSP and checkunderflow macros
# t1, t2 = scratch
# gp = scratch
# ra belongs to call / ret. An interrupt routine may use ra, t0-t2 and a0-a5:
# those are what the hardware prologue saves (see 12-ticks.s, tick_isr).

# The _start entry label must come first: it is the vector table at 0x0, as
# in WCH's startup code. Reset always starts at 0x0; mtvec = 0x0 | 3
# (vectored, entries are addresses) sends an NMI to entry 2 and every
# exception to entry 3 (EXC). The QingKe V2 needs the table 1 KiB aligned,
# and 0x0 is. Entries 0-12 exist: 12 is the SysTick tick (12-ticks.s), the
# only interrupt; enabling another one needs the table extended to its
# number. Never tell reset from a trap by mcause: on silicon it is not 0
# after reset (the board read 0x800000D9).
.text
.global _start
_start:
.option push
.option norvc                       # entry 0 must be a 4-byte jump, not a 2-byte c.j
    j boot                          # 0x00: reset
    .word 0                         # 0x04: vector 1, reserved
    .word interrupt_handler         # 0x08: vector 2, NMI
    .word interrupt_handler         # 0x0C: vector 3, EXC (all exceptions)
    .word 0, 0, 0, 0, 0, 0, 0, 0    # 0x10-0x2C: vectors 4-11, reserved or not enabled
    .word tick_isr                  # 0x30: vector 12, SysTick: the tick (12-ticks.s)
.option pop

# include the chip's constants (RAM size, registers, pins) from src/mcu.s
.include "mcu.s"

# include source files from src/
.include "01-variables-constants.s"
.include "02-macros.s"
.include "03-interrupts.s"
.include "04-io-helpers.s"
.include "05-internal-functions.s"
.include "06-initialization.s"
.include "07-error-handling.s"
.include "08-primitives.s"        # every machine-code word, sorted by function
.include "09-interpreter.s"
.include "10-forth-words.s"       # colon words kept in flash as threads
.include "11-flash.s"             # flash: source lines (line p load wipe) and user pages
.include "12-ticks.s"             # ticks and ms: the SysTick counter, and the tick interrupt
.include "13-modem.s"             # mkey? mkey memit mtimeout >modem <modem: USART2 + DMA ring

# Header of the last word in flash. defcode/defword chain the words in
# assembly order through `link` (02-macros.s); LATEST starts here.
.equ last_word, link
