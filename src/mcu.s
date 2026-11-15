##
# CH32V006F8U6 (QingKe V2C, RV32EC + Zmmul; QFN20, 62 KiB flash, 8 KiB SRAM)
#
# The chip's constants (RAM size, register addresses and bits, pins), one
# section per peripheral, and the two routines that set up the clock, the
# console UART and its pins.
#
# Sections and tables named in the comments are those of the CH32V00x
# reference manual V1.5 (docs/ch32v006/CH32V00XRM.PDF) unless the processor
# manual is named. The RCC, GPIOD and USART1 addresses were also checked
# against the ch32fun project headers (ch32x00xhw.h, used for
# CH32V005/006/007).
##

.equ CELL, 4                            # 32-bits cell size

##
# RAM
##
.equ RAM_BASE, 0x20000000               # base address of RAM
# 01-variables-constants.s builds the RAM map down from RAM_BASE + RAM_SIZE.
# linker.ld names the RAM too (LENGTH = 8k) but places nothing there; keep
# the two equal.
.equ RAM_SIZE, 1024 * 8                 # 8 KiB

##
# Clock (RCC), chapter 3
# HSI is 24 MHz on the CH32V00x family and is the sysclk source at reset.
# uart_init below forces the AHB prescaler to /1 so HCLK = 24 MHz
# deterministically, regardless of the reset default of RCC_CFGR0.
##
.equ CPU_FREQ, 24000000
.equ RCC_BASE, 0x40021000       # Table 3-1
.equ RCC_CFGR0, 0x04            # 3.4.2 clock configuration register 0 (0x20 at reset)
.equ RCC_HBPCENR, 0x14          # 3.4.6 HB peripheral clock enable register
.equ RCC_PB2PCENR, 0x18         # 3.4.7 PB2 peripheral clock enable register
.equ RCC_DMA1EN, (1 << 0)       # HBPCENR bit 0
.equ RCC_AFIOEN, (1 << 0)       # PB2PCENR bit 0
.equ RCC_IOPDEN, (1 << 5)       # PB2PCENR bit 5: port D
.equ RCC_USART2EN, (1 << 13)    # PB2PCENR bit 13 (USART2 hangs off PB2 here, next to USART1)
.equ RCC_USART1EN, (1 << 14)    # PB2PCENR bit 14

##
# Port D (GPIO) and the pin remap (AFIO), chapter 7
##
.equ GPIOD_BASE, 0x40011400     # Table 7-16
.equ GPIOD_CFGLR, 0x00          # 7.3.1.1 configuration register low: 4 bits a pin,
                                # CNF[1:0], a reserved bit, MODE (1 = output)
.equ GPIOD_INDR, 0x08           # 7.3.1.2 input data register
.equ GPIOD_BSHR, 0x10           # 7.3.1.4 bit set/reset register (low half sets)
.equ GPIOD_BCR, 0x14            # 7.3.1.5 bit clear register (write 1 = output 0)
.equ AFIO_PCFR1, 0x4001000C     # 7.3.2.2 remap register 1
.equ AFIO_USART2_RM, (7 << 20)  # USART2_RM[22:20]
.equ AFIO_USART2_PD2_PD3, (3 << 20)  # 011: TX on PD2, RX on PD3 (Table 7-11), the only
                                # USART2 remap the QFN20 can use

# The skip button is PD4, an input with pull-down; holding it HIGH (button to
# 3V3) during reset keeps line 0 from loading and boots to a bare ok prompt.
# Active-high so that an unwired pin (and the emulator's all-zero GPIO
# reads) means "load line 0". gpio_init samples it with PD5 driven low:
# on the WeAct board the closed solder bridges SB3/SB4 join PD4 to PD5, and
# PD5 is otherwise high (idle UART TX, or the WCH-LinkE's RX pull-up).
.equ SKIP_BIT, (1 << 4)         # PD4

##
# USART1 and USART2, chapter 14. The two have the same registers.
# USART1 is the console: TX = PD5, RX = PD6 (its default mapping).
# USART2 is the modem (13-modem.s): TX = PD2, RX = PD3, its receiver emptied
# by DMA1 channel 7.
##
.equ USART1_BASE, 0x40013800    # Table 14-2
.equ USART2_BASE, 0x40004400    # Table 14-3
.equ USART_STATR, 0x00          # 14.8.1 status register
.equ USART_DATAR, 0x04          # 14.8.2 data register
.equ USART_BRR, 0x08            # 14.8.3 baud rate register (USARTDIV in 1/16ths)
.equ USART_CTLR1, 0x0C          # 14.8.4 control register 1
.equ USART_CTLR2, 0x10          # 14.8.5 control register 2 (STOP[13:12])
.equ USART_CTLR3, 0x14          # 14.8.6 control register 3
.equ USART_STATR_RXNE, (1 << 5) # a received byte waits in the data register
.equ USART_STATR_TXE, (1 << 7)  # the data register can take the next byte
.equ USART_CTLR1_RE, (1 << 2)   # receiver on
.equ USART_CTLR1_TE, (1 << 3)   # transmitter on
.equ USART_CTLR1_UE, (1 << 13)  # USART on
.equ USART_CTLR3_DMAR, (1 << 6) # received bytes go to the DMA
.equ BAUD_RATE, 115200          # the console
.equ MODEM_BAUD, 115200         # the modem

##
# DMA1, chapter 8
##
.equ DMA1_BASE, 0x40020000      # Table 8-3; USART2_RX is channel 7 (Table 8-2)
.equ DMA_CFGR7, 0x80            # 8.3.3 channel 7 configuration (0x08 + (7-1)*20)
.equ DMA_CNTR7, 0x84            # 8.3.4 channel 7 transfers left, NDT[15:0]
.equ DMA_PADDR7, 0x88           # 8.3.5 channel 7 peripheral address
.equ DMA_MADDR7, 0x8C           # 8.3.6 channel 7 memory address
.equ DMA_CFGR_EN, (1 << 0)      # channel on
.equ DMA_CFGR_CIRC, (1 << 5)    # circular: CNTR reloads at 0
.equ DMA_CFGR_MINC, (1 << 7)    # memory address steps on; DIR = 0 (peripheral to memory),
                                # PSIZE = MSIZE = 00 (8 bits), PL = 00 (low)

##
# FPEC (flash controller), chapter 18, for the source lines and the user flash
# The V006 fast page is 256 bytes (the CH32V003's is 64): fast erase (FTER)
# and fast programming (FTPG, through a 256-byte page buffer) both work on
# whole pages and need the MODEKEYR unlock on top of KEYR. Standard halfword
# programming (PG) is not used: it reportedly corrupts neighbouring halfwords
# on V006 silicon.
##
.equ FLASH_R_BASE, 0x40022000   # Table 18-2
.equ FLASH_ACTLR, 0x00          # 18.3.1 control register: LATENCY[1:0], the wait states
.equ FLASH_KEYR, 0x04           # KEYR: unlock CTLR (KEY1 then KEY2)
.equ FLASH_STATR, 0x0C          # STATR: BSY in bit 0
.equ FLASH_CTLR, 0x10           # CTLR: STRT, FTPG, FTER, BUFLOAD, BUFRST
.equ FLASH_ADDR, 0x14           # ADDR: page address for erase / programming
.equ FLASH_MODEKEYR, 0x24       # MODEKEYR: unlock the fast (page) modes
.equ FLASH_ACTLR_LATENCY_1, 1   # LATENCY = 01: one wait state
.equ FLASH_KEY1, 0x45670123
.equ FLASH_KEY2, 0xCDEF89AB
.equ FLASH_CTLR_STRT, (1 << 6)  # start an erase or a page programming
.equ FLASH_CTLR_FTPG, (1 << 16) # fast page programming mode
.equ FLASH_CTLR_FTER, (1 << 17) # fast page erase mode
.equ FLASH_CTLR_BUFLOAD, (1 << 18) # load the latched word into the page buffer
.equ FLASH_CTLR_BUFRST, (1 << 19)  # clear the page buffer
.equ FLASH_STATR_BSY, (1 << 0)  # operation in progress
.equ FLASH_PAGE, 256            # fast page size in bytes

##
# SysTick (STK), for ticks and ms (12-ticks.s)
# 6.5.4 "STK Register Description" (Table 6-5), and QingKe V2 processor
# manual V1.3, chapter 4: a 32-bit up-counter in the core, clocked by HCLK or
# HCLK/8. All four registers reset to 0.
##
.equ STK_BASE, 0xE000F000       # Table 6-5: R32_STK_CTLR is at the base
.equ STK_CTLR, 0x00             # 6.5.4.1 System Count Control Register
.equ STK_SR, 0x04               # 6.5.4.2 System Count Status Register (CNTIF in bit 0)
.equ STK_CNTL, 0x08             # 6.5.4.3 System Counter Register, CNT[31:0]
.equ STK_CMPLR, 0x10            # 6.5.4.4 Counting Comparison Register, CMP[31:0]
.equ STK_CTLR_STE, (1 << 0)     # 1: the counter runs, 0: it stops
.equ STK_CTLR_STIE, (1 << 1)    # 1: counter interrupt enabled
.equ STK_CTLR_STCLK, (1 << 2)   # 1: HCLK, 0: HCLK/8
.equ STK_CTLR_STRE, (1 << 3)    # 1: restart from 0 at the compare value, 0: keep counting up
.equ STK_TICKS_PER_MS, CPU_FREQ / 8 / 1000   # HCLK/8 = 3 MHz: 3000 ticks per ms

# The tick interrupt (12-ticks.s), SysTick's compare match
.equ IRQ_SYSTICK, 12            # 6.2: interrupt 12, vector table entry 12 (address 0x30)
.equ PFIC_IENR0, 0xE000E100     # processor manual 3.1, Table 3-2: interrupt enable set,
                                # bit n lets interrupt n through (write 1, write-only)
.equ CSR_INTSYSCR, 0x804        # processor manual 3.2: interrupt system control
.equ INTSYSCR_HWSTKEN, (1 << 0) # HPE on (3.4); INESTEN (bit 1, nesting) stays 0
.equ TICK_PERIOD, STK_TICKS_PER_MS * 2   # a tick every 2 ms
.equ TICK_MARGIN, 100           # ticks (33 us): how far ahead of the count a new compare must be

.balign CELL
# Initialize the clock and the console UART (USART1)
uart_init:
    # The CH32V00x family requires 1 flash wait state for 15 MHz < SYSCLK <=
    # 24 MHz (and 2 above that; 18.3.1) -- unlike the CH32V003, which runs
    # 0-wait to 25 MHz. Raising HCLK to 24 MHz with the 0-wait reset default
    # corrupts instruction fetches and the chip falls into a reset loop. Must
    # be set BEFORE the prescaler change below.
    li t0, FLASH_R_BASE                     # the flash controller
    li t1, FLASH_ACTLR_LATENCY_1            # one wait state
    sw t1, FLASH_ACTLR(t0)

    # force HCLK = SYSCLK = HSI (24 MHz)
    # CFGR0 is written wholesale to 0, not only HPRE[7:4] cleared. Observed
    # on hardware: a read-modify-write of HPRE alone left the UART clock at
    # 12 MHz (output at exactly half baud), i.e. the V006 resets with a /2
    # divider in some other CFGR0 field. ch32fun's SystemInit also does a
    # full write (CFGR0 = RCC_HPRE_DIV1 = 0). Writing 0 selects HSI as sysclk
    # (already active), all prescalers /1, MCO off, PLL bits cleared (PLL is
    # off at reset) -- all safe.
    li t0, RCC_BASE
    sw zero, RCC_CFGR0(t0)                  # HSI sysclk, every prescaler = /1

    # enable the peripheral clocks of USART1 and port D (AFIO is not needed
    # here: USART1 uses its default pin mapping)
    lw t1, RCC_PB2PCENR(t0)
    li t2, RCC_USART1EN | RCC_IOPDEN
    or t1, t1, t2                           # add the enabled bits to the existing value
    sw t1, RCC_PB2PCENR(t0)

    # set the baud rate: BRR = HCLK (24 MHz) / baud rate (115200 bps) = 208
    # (BRR holds USARTDIV in 1/16ths: mantissa [15:4], fraction [3:0], so the
    # plain integer quotient is already in the right format; actual rate is
    # 24e6/208 = 115384 bps, +0.16% error)
    li t0, USART1_BASE
    li t1, (CPU_FREQ / BAUD_RATE)           # the baud rate divider
    sw t1, USART_BRR(t0)

    # set the stop bits
    li t1, (0 << 12) | (0 << 13)            # STOP (bits 12 and 13) = 00: 1 stop bit
    sw t1, USART_CTLR2(t0)

    # disable hardware flow control, half-duplex, etc
    sw zero, USART_CTLR3(t0)

    # enable receiver, transmitter, uart (no USART interrupt enable is set:
    # the console is polled)
    li t1, USART_CTLR1_RE | USART_CTLR1_TE | USART_CTLR1_UE
    sw t1, USART_CTLR1(t0)

    ret

.balign CELL
# Initialize the GPIO: USART1's default mapping is TX = PD5, RX = PD6, i.e.
# port D CFGLR nibbles 5 and 6
# returns: a0 = skip button (0 = released, SKIP_BIT = held)
# clobbers: t0, t1, t2, a1, a2
gpio_init:
    li t0, GPIOD_BASE
    lw t1, GPIOD_CFGLR(t0)                  # the configuration of pins 0-7

    # Sample the skip button (PD4) with PD5 driven low.
    # On the WeAct board the closed solder bridges SB3/SB4 join PD4 to PD5
    # (through USB D-, 33 R + 1.5 k). As the UART TX, PD5 idles high; released
    # as an input, it is still pulled high by the WCH-LinkE's RX. Either way
    # PD4 would read as a held button. Driven low, PD5 pulls PD4 low through
    # the 1.5 k, which the button (PD4 straight to 3V3) still overrides.
    # Step 1: PD4 MODE4 = 0 (input), CNF4 = 10 (input with pull-up/pull-down)
    # -> nibble 0b1000; OUTDR bit 4 is 0 at reset = pull-down. PD5 is left as
    # it is (high), so the pull-down settles without a glitch on TX.
    li t2, ~(0xf << (4*4))                  # load bitmask to clear the 4 config bits of pin 4
    and t1, t1, t2                          # clear CNF4[1:0] and MODE4
    li t2, (0b1000 << (4*4))                # input with pull-up/pull-down
    or t1, t1, t2                           # set the pin 4 bits
    sw t1, GPIOD_CFGLR(t0)
    li t2, 64                               # let the pull-down settle (~10 us)
gpio_settle:
    addi t2, t2, -1
    bnez t2, gpio_settle

    # Step 2: prepare the final configuration in a2: TX on pin 5 of port D,
    # MODE5 = 1 (output), CNF5 = 10 (alternate function push-pull) -> nibble
    # 0b1001; RX on pin 6, MODE6 = 0 (input), CNF6 = 01 (floating input) ->
    # nibble 0b0100. a1 is the same with PD5 a general purpose push-pull
    # output (0b0001) whose latch is 0.
    li t2, ~((0xf << (4*5)) | (0xf << (4*6)))
    and t1, t1, t2                          # clear the pin 5 and pin 6 bits
    li t2, (0b1001 << (4*5)) | (0b0100 << (4*6))
    or a2, t1, t2                           # a2 = TX on PD5, RX on PD6
    li t2, (0b0001 << (4*5)) | (0b0100 << (4*6))
    or a1, t1, t2                           # a1 = the same with PD5 a plain output
    li t2, (1 << 5)
    sw t2, GPIOD_BCR(t0)                    # PD5 output latch = 0

    # Step 3: the sample. TX is low only from this store to the next one,
    # ~0.5 us (about a sixteenth of a bit at 115200 baud), too short for the
    # receiver to see a character; through the 1.5 k, PD4 follows in ~50 ns.
    sw a1, GPIOD_CFGLR(t0)                  # PD5 driven low
    nop
    nop
    nop
    nop
    lw a0, GPIOD_INDR(t0)                   # read the port D inputs
    sw a2, GPIOD_CFGLR(t0)                  # PD5 is the UART TX again (idle high)
    andi a0, a0, SKIP_BIT                   # keep the button (PD4)

    ret
