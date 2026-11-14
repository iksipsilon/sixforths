##
# CH32V006F8U6 (QingKe V2C, RV32EC + Zmmul; QFN20, 62 KiB flash, 8 KiB SRAM)
#
# CH32V006 PORT: this file is a full rewrite of src/mcus/gd32vf103/mcu.s.
# The WCH peripheral map is STM32F1-flavoured like the GD32VF103's, so the
# register offsets are mostly identical; what changed is the port/pins
# (USART1 on PD5/PD6 instead of USART0 on PA9/PA10), the RCC enable bits,
# and the clock (HSI = 24 MHz instead of the GD32V's 8 MHz IRC).
#
# Register facts cross-checked against the ch32fun project headers
# (ch32x00xhw.h, used for CH32V005/006/007):
#   RCC    base 0x40021000, APB2PCENR at +0x18, CFGR0 at +0x04
#   GPIOD  base 0x40011400, CFGLR at +0x00
#   USART1 base 0x40013800, STATR +0x00, DATAR +0x04, BRR +0x08,
#                           CTLR1 +0x0C, CTLR2 +0x10, CTLR3 +0x14
##

.equ CELL, 4                            # 32-bits cell size
.equ RAM_BASE, 0x20000000               # base address of RAM (same as GD32V)
# CH32V006 PORT: RAM_SIZE was the only line of the old board file (board.s).
# 01-variables-constants.s builds the RAM map down from RAM_BASE + RAM_SIZE.
# linker.ld names the RAM too (LENGTH = 8k) but places nothing there; keep
# the two equal.
.equ RAM_SIZE, 1024 * 8                 # 8 KiB (the Longan Nano had 20 KiB)
.equ STACK_SIZE, 256                    # 256 Bytes

# UART (USART1 on the CH32V006; default mapping: TX = PD5, RX = PD6)
.equ UART_BASE_ADDRESS, 0x40013800
.equ UART_RX_STATUS, 0x00       # USART status register offset (USART_STATR)
.equ UART_RX_DATA, 0x04         # data register offset (USART_DATAR)
.equ UART_TX_STATUS, 0x00       # USART status register offset (USART_STATR)
.equ UART_TX_DATA, 0x04         # data register offset (USART_DATAR)
.equ UART_RX_BIT, (1 << 5)      # read data register not empty bit (RXNE) - same bit as GD32V RBNE
.equ UART_TX_BIT, (1 << 7)      # transmit data register empty bit (TXE) - same bit as GD32V TBE

# Clock: HSI is 24 MHz on the CH32V00x family and is the sysclk source at
# reset. uart_init below forces the AHB prescaler to /1 so HCLK = 24 MHz
# deterministically, regardless of the reset default of RCC_CFGR0.
.equ CPU_FREQ, 24000000
.equ BAUD_RATE, 115200

##
# FPEC (flash controller) - CH32V006 PORT, for the source-replay log
# Per the CH32V00x reference manual V1.5, chapter 18. The V006 fast page is
# 256 bytes (the CH32V003's is 64): fast erase (FTER) and fast programming
# (FTPG, through a 256-byte page buffer) both work on whole pages and need
# the MODEKEYR unlock on top of KEYR. Standard halfword programming (PG) is
# not used: it reportedly corrupts neighbouring halfwords on V006 silicon.
##
.equ FLASH_R_BASE, 0x40022000   # FPEC register base (ACTLR at +0x00 is used in uart_init)
.equ FLASH_KEYR, 0x04           # KEYR: unlock CTLR (KEY1 then KEY2)
.equ FLASH_STATR, 0x0C          # STATR: BSY in bit 0
.equ FLASH_CTLR, 0x10           # CTLR: STRT, FTPG, FTER, BUFLOAD, BUFRST
.equ FLASH_ADDR, 0x14           # ADDR: page address for erase / programming
.equ FLASH_MODEKEYR, 0x24       # MODEKEYR: unlock the fast (page) modes
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
# Boot-replay skip button - CH32V006 PORT
# PD4 is configured as an input with pull-down; holding it HIGH (button to
# 3V3) during reset skips the source-replay and boots to a bare ok prompt.
# Active-high so that an unwired pin (and the emulator's all-zero GPIO
# reads) means "replay normally". gpio_init samples it with PD5 driven low:
# on the WeAct board the closed solder bridges SB3/SB4 join PD4 to PD5, and
# PD5 is otherwise high (idle UART TX, or the WCH-LinkE's RX pull-up).
##
.equ GPIOD_BASE, 0x40011400
.equ GPIOD_INDR, 0x08           # input data register offset
.equ GPIOD_BCR, 0x14            # bit clear register offset (write 1 = output 0)
.equ SKIP_BIT, (1 << 4)     # PD4

##
# SysTick (STK) - CH32V006 PORT, for ticks and ms (13-ticks.s)
# Reference manual V1.5, 6.5.4 "STK Register Description" (Table 6-5), and
# QingKe V2 processor manual V1.3, chapter 4: a 32-bit up-counter in the
# core, clocked by HCLK or HCLK/8. All four registers reset to 0.
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

# CH32V006 PORT: the tick interrupt (13-ticks.s), SysTick's compare match
.equ IRQ_SYSTICK, 12            # RM 6.2: interrupt 12, vector table entry 12 (address 0x30)
.equ PFIC_IENR0, 0xE000E100     # processor manual 3.1, Table 3-2: interrupt enable set,
                                # bit n lets interrupt n through (write 1, write-only)
.equ CSR_INTSYSCR, 0x804        # processor manual 3.2: interrupt system control
.equ INTSYSCR_HWSTKEN, (1 << 0) # HPE on (3.4); INESTEN (bit 1, nesting) stays 0
.equ TICK_PERIOD, STK_TICKS_PER_MS * 2   # a tick every 2 ms
.equ TICK_MARGIN, 100           # ticks (33 us): how far ahead of the count a new compare must be

##
# Modem UART - CH32V006 PORT, for 14-modem.s: USART2 on PD2 (TX) / PD3 (RX),
# its receiver emptied by DMA1 channel 7. Reference manual V1.5 sections given.
##
.equ RCC_BASE, 0x40021000
.equ RCC_HBPCENR, 0x14          # 3.4.6 HB peripheral clock enable register
.equ RCC_PB2PCENR, 0x18         # 3.4.7 PB2 peripheral clock enable register
.equ RCC_DMA1EN, (1 << 0)       # HBPCENR bit 0
.equ RCC_AFIOEN, (1 << 0)       # PB2PCENR bit 0
.equ RCC_USART2EN, (1 << 13)    # PB2PCENR bit 13 (USART2 hangs off PB2 here, next to USART1)
.equ AFIO_PCFR1, 0x4001000C     # 7.3.2.2 remap register 1
.equ AFIO_USART2_RM, (7 << 20)  # USART2_RM[22:20]
.equ AFIO_USART2_PD2_PD3, (3 << 20)  # 011: TX on PD2, RX on PD3 (Table 7-11), the only
                                # USART2 remap the QFN20 can use
.equ GPIOD_BSHR, 0x10           # 7.3.1.4 bit set/reset register (low half sets)
.equ USART2_BASE, 0x40004400    # Table 14-3
.equ USART_STATR, 0x00          # 14.8.1 status register
.equ USART_DATAR, 0x04          # 14.8.2 data register
.equ USART_BRR, 0x08            # 14.8.3 baud rate register (USARTDIV in 1/16ths)
.equ USART_CTLR1, 0x0C          # 14.8.4 control register 1
.equ USART_CTLR3, 0x14          # 14.8.6 control register 3
.equ USART_STATR_TXE, (1 << 7)  # the data register can take the next byte
.equ USART_CTLR1_UE, (1 << 13)  # USART on
.equ USART_CTLR1_TE, (1 << 3)   # transmitter on
.equ USART_CTLR1_RE, (1 << 2)   # receiver on
.equ USART_CTLR3_DMAR, (1 << 6) # received bytes go to the DMA
.equ MODEM_BAUD, 115200
.equ DMA1_BASE, 0x40020000      # Table 8-3; USART2_RX is channel 7 (Table 8-2)
.equ DMA_CFGR7, 0x80            # 8.3.3 channel 7 configuration (0x08 + (7-1)*20)
.equ DMA_CNTR7, 0x84            # 8.3.4 channel 7 transfers left, NDT[15:0]
.equ DMA_PADDR7, 0x88           # 8.3.5 channel 7 peripheral address
.equ DMA_MADDR7, 0x8C           # 8.3.6 channel 7 memory address
.equ DMA_CFGR_EN, (1 << 0)      # channel on
.equ DMA_CFGR_CIRC, (1 << 5)    # circular: CNTR reloads at 0
.equ DMA_CFGR_MINC, (1 << 7)    # memory address steps on; DIR = 0 (peripheral to memory),
                                # PSIZE = MSIZE = 00 (8 bits), PL = 00 (low)

.balign CELL
# Initialize the UART
uart_init:
    # CH32V006 PORT BUGFIX: the CH32V00x family requires 1 flash wait state
    # for 15 MHz < HCLK <= 25 MHz (and 2 above that), per the TRM -- unlike
    # the CH32V003, which runs 0-wait to 25 MHz. Raising HCLK to 24 MHz with
    # the 0-wait reset default corrupts instruction fetches and the chip
    # falls into a reset loop. Must be set BEFORE the prescaler change below.
    li t0, 0x40022000                       # load base address of the FLASH controller
    li t1, 1                                # FLASH_ACTLR_LATENCY_1 (one wait state)
    sw t1, 0x00(t0)                         # store in FLASH_ACTLR

    # force HCLK = SYSCLK = HSI (24 MHz)
    # CH32V006 PORT BUGFIX: write CFGR0 wholesale to 0 instead of only
    # clearing HPRE[7:4]. Observed on hardware: a read-modify-write of HPRE
    # alone left the UART clock at 12 MHz (output at exactly half baud), i.e.
    # the V006 resets with a /2 divider in some other CFGR0 field. ch32fun's
    # SystemInit also does a full write (CFGR0 = RCC_HPRE_DIV1 = 0). Writing
    # 0 selects HSI as sysclk (already active), all prescalers /1, MCO off,
    # PLL bits cleared (PLL is off at reset) -- all safe.
    li t0, 0x40021000                       # load base address of the RCC
    sw zero, 0x04(t0)                       # RCC_CFGR0 = 0: HSI sysclk, every prescaler = /1

    # enable the peripheral clocks
    # (CH32V006 PORT: IOPDEN bit 5 for port D instead of PAEN bit 2 for
    # port A; USART1EN is bit 14 as on the GD32V; AFIO not needed since we
    # use the default pin mapping)
    lw t1, 0x18(t0)                         # load value from the APB2 enable register (RCC_APB2PCENR)
    li t2, (1 << 14) | (1 << 5)             # set USART1EN (bit 14), IOPDEN (bit 5)
    or t1, t1, t2                           # add the enabled bits to the existing value
    sw t1, 0x18(t0)                         # store value in RCC_APB2PCENR register at offset 0x18

    # set the baud rate: BRR = HCLK (24 MHz) / baud rate (115200 bps) = 208
    # (BRR holds USARTDIV in 1/16ths: mantissa [15:4], fraction [3:0], so the
    # plain integer quotient is already in the right format; actual rate is
    # 24e6/208 = 115384 bps, +0.16% error)
    li t0, UART_BASE_ADDRESS                # load USART1 base address
    li t1, (CPU_FREQ / BAUD_RATE)           # load baud rate divider
    sw t1, 0x08(t0)                         # store the value in the Baud rate register (USART_BRR)

    # set the stop bits
    li t1, (0 << 12) | (0 << 13)            # set STOP (bits 12 and 13) to 00 (1 stop bit)
    sw t1, 0x10(t0)                         # store the value in the USART Control register 2 (USART_CTLR2)

    # disable hardware flow control, half-duplex, etc
    sw zero, 0x14(t0)                       # store the value in the USART Control register 3 (USART_CTLR3)

    # enable receiver, transmitter, uart
    # (CH32V006 PORT: the GD32V code also set RBNEIE/TCIE/TBEIE interrupt
    # enables; dropped here since the interrupt handler is a stub, interrupts
    # are globally disabled, and all PFIC channels are off at reset)
    li t1, (1 << 2) | (1 << 3) | (1 << 13)  # set RE (bit 2), TE (bit 3), UE (bit 13)
    sw t1, 0x0C(t0)                         # store the value in the USART Control register 1 (USART_CTLR1)

uart_done:
    ret

.balign CELL
# Initialize the GPIO
# (CH32V006 PORT: USART1 default mapping is TX = PD5, RX = PD6, i.e. port D
# CFGLR nibbles 5 and 6, instead of the GD32V's PA9/PA10 in CTL1)
# returns: a0 = replay-skip button (0 = released, SKIP_BIT = held)
# clobbers: t0, t1, t2, a1, a2
gpio_init:
    li t0, 0x40011400                       # load base address of GPIOD
    lw t1, 0x00(t0)                         # load value from the Port config register low (GPIOD_CFGLR)

    # CH32V006 PORT: sample the replay-skip button (PD4) with PD5 driven low.
    # On the WeAct board the closed solder bridges SB3/SB4 join PD4 to PD5
    # (through USB D-, 33 R + 1.5 k). As the UART TX, PD5 idles high; released
    # as an input, it is still pulled high by the WCH-LinkE's RX. Either way
    # PD4 would read as a held button. Driven low, PD5 pulls PD4 low through
    # the 1.5 k, which the button (PD4 straight to 3V3) still overrides.
    # Step 1: PD4 MODE4 = 00 (input), CNF4 = 10 (input with pull-up/pull-down)
    # -> nibble 0b1000; OUTDR bit 4 is 0 at reset = pull-down. PD5 is left as
    # it is (high), so the pull-down settles without a glitch on TX.
    li t2, ~(0xf << (4*4))                  # load bitmask to clear the 4 config bits of pin 4
    and t1, t1, t2                          # clear MODE4[1:0], CNF4[1:0]
    li t2, (0b1000 << (4*4))                # input with pull-up/pull-down
    or t1, t1, t2                           # set the pin 4 bits
    sw t1, 0x00(t0)                         # store the value in GPIOD_CFGLR
    li t2, 64                               # let the pull-down settle (~10 us)
gpio_settle:
    addi t2, t2, -1
    bnez t2, gpio_settle

    # Step 2: prepare the final configuration in a2: TX on pin 5 of port D,
    # MODE5 = 01 (output 10 MHz), CNF5 = 10 (alternate function push-pull)
    # -> nibble 0b1001; RX on pin 6, MODE6 = 00 (input), CNF6 = 01 (floating
    # input) -> nibble 0b0100. a1 is the same with PD5 a general purpose
    # push-pull output (0b0001) whose latch is 0.
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
    sw a1, 0x00(t0)                         # PD5 driven low
    nop
    nop
    nop
    nop
    lw a0, GPIOD_INDR(t0)                   # read the port D inputs
    sw a2, 0x00(t0)                         # PD5 is the UART TX again (idle high)
    andi a0, a0, SKIP_BIT               # keep the button (PD4)

gpio_done:
    ret
