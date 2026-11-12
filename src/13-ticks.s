##
# Time: ticks and ms (CH32V006 PORT)
#
# SysTick (registers in mcu.s, reference manual 6.5.4) runs free on HCLK/8 =
# 3 MHz: STK_TICKS_PER_MS = 3000 ticks per millisecond, and the 32-bit count
# wraps every 2^32 / 3 MHz = 23.9 minutes. Interval arithmetic is unsigned,
# so  ticks t0 -  is the time since t0 even across the wrap, as long as the
# interval is shorter than 23.9 minutes. Nothing here uses an interrupt: the
# words read the counter. (The tick interrupt planned for later can use the
# compare register, CMPLR, and leave the counter running.)
##

.text
.balign CELL
# start the counter from 0 on HCLK/8, with no auto-reload and no interrupt.
# Called from boot; after `reboot` the counter is still running, hence the stop.
# clobbers: t0, t1
ticks_init:
    li t0, STK_BASE
    sw zero, STK_CTLR(t0)       # stop the counter (STE = 0)
    sw zero, STK_CNTL(t0)       # count from 0
    li t1, STK_CTLR_STE         # run; STCLK = 0 (HCLK/8), STRE = 0, STIE = 0
    sw t1, STK_CTLR(t0)
    ret

# ticks ( -- u )        The SysTick count: 3000 per millisecond, wraps every
# 23.9 minutes. ticks t0 - is the number of ticks since t0.
defcode "ticks",5,,TICKS
    li a1, STK_BASE
    lw a2, STK_CNTL(a1)
    PUSH a2
    NEXT

# ms ( n -- )           Wait n milliseconds, polling SysTick. CH32V006 PORT:
# n is signed (Forth-2012 says u): n <= 0 returns at once, so a stray -1
# cannot hang the phone for 49 days. Each millisecond begins exactly
# STK_TICKS_PER_MS ticks after the one before, so a long wait does not drift,
# and n * 3000 never has to fit in a cell.
defcode "ms",2,,MS
    checkunderflow 0
    POP a1                      # a1 = milliseconds still to wait
    li a2, STK_BASE
    lw a3, STK_CNTL(a2)         # a3 = the count when the current millisecond began
    li a4, STK_TICKS_PER_MS
ms_next:
    blez a1, ms_done            # signed: n <= 0 waits no time
ms_wait:
    lw a5, STK_CNTL(a2)
    sub a5, a5, a3              # ticks since this millisecond began (right across the wrap)
    bltu a5, a4, ms_wait
    add a3, a3, a4              # the next millisecond begins 3000 ticks after this one
    addi a1, a1, -1
    j ms_next
ms_done:
    NEXT
