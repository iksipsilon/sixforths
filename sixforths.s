/*
FiveForths - https://github.com/aw/FiveForths
RISC-V Forth implementation

The MIT License (MIT)
Copyright (c) 2021~ Alexander Williams, https://a1w.ca
*/

##
# Forth registers
##

# CH32V006 PORT: the QingKe V2C core is RV32EC (registers x0..x15 only), so all
# registers above x15 were remapped injectively (1:1, no sharing), which preserves
# every liveness and clobber relation of the original code:
#   s2 -> s0 (RSP; the FP convention serves no purpose here: there are no stack
#             frames, no C interop, and no unwinder in this program)
#   t3 -> a4, t4 -> a5, t5 -> gp, t6 -> tp
#   s3 -> eliminated (spilled to the return stack in 04-io-helpers.s)
# gp/tp are safe targets: no C runtime, no .sdata relaxation, no threads.
#
# The four Forth registers: the three "s" registers and the first argument
# register.
# sp = DSP = data stack pointer
# s0 = RSP = return stack pointer (was s2; s0 no longer reserved as FP)
# s1 = IP  = instruction pointer
# a0 = W   = working register (NEXT hands it to the code-field routine)
# sp, s0 and s1 are also the registers no subroutine and no interrupt touches.
# With IP = s1 and W = a0, every instruction of NEXT has a 2-byte form.
#
# Scratch inside a primitive:
# a1 = X, a2 = Y, a3 = Z = working registers
# a4 = scratch (was t3)
# a5 = scratch (was t4); NEXT uses it as its temporary
# t0 = temporary of the PUSH, PUSHRSP, POPRSP and checkunderflow macros
# t1, t2 = scratch
# gp = scratch (was t5)
# tp = scratch (was t6)
# ra belongs to call / ret. An interrupt routine may use ra, t0-t2 and a0-a5
# only: those are what the hardware prologue saves (see 02-macros.s, PUSH).

# Ensure the _start entry label is defined first
# CH32V006 PORT: a vector table at 0x0, as in WCH's startup code. Reset
# always starts at 0x0; mtvec = 0x0 | 3 (vectored, entries are addresses)
# sends an NMI to entry 2 and every exception to entry 3 (EXC). The QingKe V2
# needs the table 1 KiB aligned, and 0x0 is. Only entries 0-3 exist: enabling
# any interrupt needs a longer table. Never tell reset from a trap by mcause:
# on silicon it is not 0 after reset (the board read 0x800000D9).
.text
.global _start
_start:
.option push
.option norvc                       # entry 0 must be a 4-byte jump,
.option norelax                     # and the linker must not shorten it
    j boot                          # 0x00: reset
    .word 0                         # 0x04: vector 1, reserved
    .word interrupt_handler         # 0x08: vector 2, NMI
    .word interrupt_handler         # 0x0C: vector 3, EXC (all exceptions)
.option pop

# include board-specific functions and constants from src/boards/<board>/
.include "board.s"

# include MCU-specific functions and constants from src/mcus/<MCU>/
.include "mcu.s"

# include source files from src/
.include "01-variables-constants.s"
.include "02-macros.s"
.include "03-interrupts.s"
.include "04-io-helpers.s"
.include "05-internal-functions.s"
.include "06-initialization.s"
.include "07-error-handling.s"
.include "08-primitives.s"        # every machine-code word, sorted by function (CH32V006 port)
.include "09-interpreter.s"
.include "10-forth-words.s"       # colon words kept in flash as threads (CH32V006 port)
.include "12-flash-log.s"         # source-replay log: flash persistence (CH32V006 port)
.include "13-ticks.s"             # ticks and ms: the SysTick counter (CH32V006 port)

# CH32V006 PORT: header of the last word in flash. defcode/defword chain the
# words in assembly order through `link` (02-macros.s); LATEST starts here.
.equ last_word, link
