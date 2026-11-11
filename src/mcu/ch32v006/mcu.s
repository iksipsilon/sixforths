##
# CH32V006 (QingKe V2C, RV32EC + Zmmul)
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
.equ LOG_SKIP_BIT, (1 << 4)     # PD4

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
# returns: a0 = replay-skip button (0 = released, LOG_SKIP_BIT = held)
gpio_init:
    li t0, 0x40011400                       # load base address of GPIOD
    lw t1, 0x00(t0)                         # load value from the Port config register low (GPIOD_CFGLR)

    # CH32V006 PORT: sample the replay-skip button (PD4) with PD5 driven low.
    # On the WeAct board the closed solder bridges SB3/SB4 join PD4 to PD5
    # (through USB D-, 33 R + 1.5 k). As the UART TX, PD5 idles high; released
    # as an input, it is still pulled high by the WCH-LinkE's RX. Either way
    # PD4 would read as a held button. Driven low, PD5 pulls PD4 low through
    # the 1.5 k, which the button (PD4 straight to 3V3) still overrides.
    # PD4: MODE4 = 00 (input), CNF4 = 10 (input with pull-up/pull-down) ->
    # nibble 0b1000; OUTDR bit 4 is 0 at reset = pull-down. PD5: general
    # purpose push-pull output, 10 MHz (0b0001), latch 0. The low pulse on
    # TX lasts ~3 us, under half a bit at 115200 baud, so the receiver
    # should not see a character.
    li t2, (1 << 5)
    sw t2, GPIOD_BCR(t0)                    # PD5 output latch = 0
    li t2, ~((0xf << (4*4)) | (0xf << (4*5)))
    and t1, t1, t2                          # clear the pin 4 and pin 5 bits
    li t2, (0b1000 << (4*4)) | (0b0001 << (4*5))
    or t1, t1, t2                           # PD4 pulled down, PD5 driven low
    sw t1, 0x00(t0)                         # store the value in GPIOD_CFGLR
    li t2, 16                               # let PD4 settle (~3 us)
gpio_settle:
    addi t2, t2, -1
    bnez t2, gpio_settle
    lw a0, GPIOD_INDR(t0)                   # read the port D inputs
    andi a0, a0, LOG_SKIP_BIT               # keep the button (PD4)

    # configure TX on pin 5 of port D: MODE5 = 01 (output 10 MHz), CNF5 = 10
    # (alternate function push-pull) -> nibble 0b1001
    li t2, ~(0xf << (4*5))                  # load bitmask to clear the 4 config bits of pin 5
    and t1, t1, t2                          # clear MODE5[1:0], CNF5[1:0]
    li t2, (0b1001 << (4*5))                # AF push-pull, 10 MHz
    or t1, t1, t2                           # set the pin 5 bits

    # configure RX on pin 6 of port D: MODE6 = 00 (input), CNF6 = 01
    # (floating input) -> nibble 0b0100
    li t2, ~(0xf << (4*6))                  # load bitmask to clear the 4 config bits of pin 6
    and t1, t1, t2                          # clear MODE6[1:0], CNF6[1:0]
    li t2, (0b0100 << (4*6))                # floating input
    or t1, t1, t2                           # set the pin 6 bits

    sw t1, 0x00(t0)                         # store the value in the Port config register (GPIOD_CFGLR)

gpio_done:
    ret
