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
# sp = DSP = data stack pointer
# a0 = W   = working register
# a1 = X   = working register
# a2 = Y   = working register
# a3 = Z   = working register
# s0 = RSP = return stack pointer (was s2; s0 no longer reserved as FP)
# s1 = IP  = instruction pointer
# a4 = scratch (was t3)
# a5 = scratch (was t4)
# gp = scratch (was t5)
# tp = scratch (was t6)

# Ensure the _start entry label is defined first
.text
.global _start
_start:
    j boot

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
.include "08-forth-primitives.s"
.include "09-interpreter.s"
.include "11-eforth-primitives.s" # eForth-style kernel extensions (CH32V006 port)
.include "12-flash-log.s"         # source-replay log: flash persistence (CH32V006 port)
.include "13-ans-primitives.s"    # ANS-style assembly words (CH32V006 port)
