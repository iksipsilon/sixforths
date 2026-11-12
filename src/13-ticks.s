##
# Time: ticks and ms (CH32V006 PORT)
#
# SysTick (registers in mcu.s, reference manual 6.5.4) runs free on HCLK/8 =
# 3 MHz: STK_TICKS_PER_MS = 3000 ticks per millisecond, and the 32-bit count
# wraps every 2^32 / 3 MHz = 23.9 minutes. Interval arithmetic is unsigned,
# so  ticks t0 -  is the time since t0 even across the wrap, as long as the
# interval is shorter than 23.9 minutes. The words read the counter; the
# tick interrupt below (every 2 ms, from the compare register) leaves it
# running, so they are not affected by it.
##

.text
.balign CELL
# start the counter from 0 on HCLK/8 (no auto-reload) with its compare
# interrupt, the tick, every TICK_PERIOD; switch on HPE. Called from boot with
# interrupts off (mstatus.MIE, set at the end of boot). After `reboot` the
# counter is still running, hence the stop.
# clobbers: t0, t1
ticks_init:
    li t0, STK_BASE
    sw zero, STK_CTLR(t0)       # stop the counter (STE = 0) and its interrupt (STIE = 0)
    sw zero, STK_CNTL(t0)       # count from 0
    li t1, TICK_PERIOD
    sw t1, STK_CMPLR(t0)        # the first tick, 2 ms from now
    sw zero, STK_SR(t0)         # no match pending (CNTIF: writing 0 clears it)
    li t1, STK_CTLR_STE | STK_CTLR_STIE
    sw t1, STK_CTLR(t0)         # run, HCLK/8 (STCLK = 0), STRE = 0, compare interrupt on
    li t0, PFIC_IENR0
    li t1, (1 << IRQ_SYSTICK)
    sw t1, 0(t0)                # the PFIC lets interrupt 12 through
    li t1, INTSYSCR_HWSTKEN
    csrw CSR_INTSYSCR, t1       # HPE on, nesting off: the hardware saves ra, t0-t2, a0-a5
    li t0, var_IRQS
    sw zero, 0(t0)              # no tick taken yet
    ret

.balign CELL
# The tick: SysTick's compare interrupt, vector table entry 12, every 2 ms.
# HPE has saved ra, t0-t2 and a0-a5 below sp, and mret restores them, so only
# those may be used here; sp, s0, s1, gp and tp must not change, and nothing
# may be stored below sp. The routine is in flash, so it waits while a flash
# page is erased or programmed (the core stands still) and then runs late: if
# the next compare would already be past (or too close to catch), it is put a
# whole period after now. A compare in the past would not match again until
# the counter wraps, 23.9 minutes later.
tick_isr:
    li t0, STK_BASE
    lw t1, STK_CMPLR(t0)
    li t2, TICK_PERIOD
    add t1, t1, t2              # the next tick, one period after this one
    lw a0, STK_CNTL(t0)
    sub a1, t1, a0              # how far ahead of the count it is (signed)
    li a2, TICK_MARGIN
    bge a1, a2, tick_isr_cmp    # far enough: keep the ticks evenly spaced
    add t1, a0, t2              # late: one period from now
tick_isr_cmp:
    sw t1, STK_CMPLR(t0)        # the new compare first, so the old match is over
    sw zero, STK_SR(t0)         # CNTIF = 0 (writing 0 clears it, RM 6.5.4.2)
    li t0, var_IRQS
    lw t1, 0(t0)
    addi t1, t1, 1
    sw t1, 0(t0)                # count the tick
    mret

# irqs ( -- n )         How many ticks (one every 2 ms) the interrupt has taken
# since boot. Fewer than ticks / 6000 when flash work held the core up.
defcode "irqs",4,,IRQS
    li t1, var_IRQS
    lw t1, 0(t1)
    PUSH t1
    NEXT

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
