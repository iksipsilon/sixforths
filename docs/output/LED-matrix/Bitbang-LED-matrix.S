# ----------------------------------------------------------------------
# led_mbi5024.S  --  5x32 LED matrix, 3x MBI5024 chain, bit-banged
# Target : CH32V006 (QingKe V2C, RV32EC), HSI 24 MHz
# Build  : riscv64-unknown-elf-as -march=rv32ec_zicsr_zmmul -mabi=ilp32e
# Regs   : checked against the CH32V00X reference manual V1.5
#
# PINS                        MBI5024 pin
#   PC0  DATA  (GPIOC) -> SDI of U1 (U1.SDO->U2.SDI, U2.SDO->U3.SDI)
#   PC2  CLK   (GPIOC) -> CLK of U1, U2, U3 (shift on rising edge)
#   PA1  LE    (GPIOA) -> LE  of U1, U2, U3 (latched when LE falls)
#   PA2  OE    (GPIOA) -> OE  of U1, U2, U3 (active low; high = outputs off)
# DATA and CLK share a port so one BSHR write sets DATA and drops CLK
# together. PA1/PA2 are plain GPIO as long as AFIO PA1PA2_RM = 0 (reset
# value), i.e. no external crystal. PC1 stays free for SPI NSS.
#
# CHAIN / BIT ORDER
#   48 bits per row update, MSB first, first bit sent ends on the LAST chip.
#   Every MBI5024 has a 16-bit shift register, so each chip in the chain
#   consumes 16 clocks even though U3 only uses 5 of its outputs:
#     bits 47..32 -> U3 (row driver)      word bit n -> U3.OUTn, n=0..4 = row n
#     bits 31..16 -> U2 (columns 16..31)  word bit c -> column c
#     bits 15..0  -> U1 (columns 0..15)
#   (inside each chip the first bit sent lands on OUT15, the last on OUT0)
#
# FRAMEBUFFER
#   fb[0..4]: five 32-bit words, one per row, bit c = column c (1 = LED on)
#   row_idx : next row to refresh (0..4)
#
# REGISTERS (CH32V00X RM V1.5)
#   RCC_PB2PCENR 0x40021018: IOPAEN = bit 2, IOPCEN = bit 4
#   GPIOA 0x40010800 / GPIOC 0x40011000: CFGLR +0x00, BSHR +0x10
#   CFGLR: 4 bits per pin = CNF[1:0] (bits 3:2), reserved (bit 1), MODE (bit 0)
#          push-pull output 30 MHz = MODE 1, CNF 00 = 0x1  (reset value 0x4)
#   BSHR : bits 7:0 set pins, bits 23:16 reset pins (set wins if both)
#
# led_refresh_row clobbers a0-a5, t0-t2 (the whole RV32E temp set).
# Call it every ~2 ms (5 rows x 100 Hz frame). Roughly 450 cycles
# (~19 us at 24 MHz) per call -- estimate, measure on a scope.
# ----------------------------------------------------------------------

        .equ GPIOA,      0x40010800
        .equ GPIOC,      0x40011000
        .equ CFGLR,      0x00
        .equ BSHR,       0x10
        .equ RCC,        0x40021000
        .equ PB2PCENR,   0x18
        .equ IOPAEN,     0x04
        .equ IOPCEN,     0x10

        # GPIOC BSHR words (DATA = PC0, CLK = PC2)
        .equ CLK_SET,    0x00000004
        .equ CLK_RST,    0x00040000
        .equ DATA_MASK,  0x00010001      # flips the DATA part of the bit word
        .equ BIT0_WORD,  0x00050000      # DATA=0, CLK=0
        .equ INIT_C,     0x00050000      # idle: DATA=0, CLK=0

        # GPIOA BSHR words (LE = PA1, OE = PA2)
        .equ LE_SET,     0x00000002
        .equ LE_RST,     0x00020000
        .equ OE_SET,     0x00000004      # OE high -> outputs off
        .equ OE_RST,     0x00040000      # OE low  -> outputs on
        .equ INIT_A,     0x00020004      # idle: LE=0, OE=1 (blank)

# One bit per iteration, branch-free, constant time:
#   a1 = shift register (MSB = next bit)   a2 = DATA_MASK   a3 = BIT0_WORD
#   a4 = CLK_SET   a0 = GPIOC
#   store 1: DATA=bit and CLK=0 in one write
#   store 2: CLK=1 (MBI5024 shifts on the rising edge)
# CLK high >= 4 cycles (~165 ns), CLK low / data setup >= 1 store (~42 ns);
# MBI5024 needs 20 ns / 3 ns / 5 ns.
        .macro SENDBITS n
        .rept \n
        srai    t0, a1, 31              # 0 or -1 from the MSB
        and     t0, t0, a2              # 0 or 0x00010001
        xor     t0, t0, a3              # bit=1: 0x00040001  bit=0: 0x00050000
        sw      t0, BSHR(a0)            # DATA = bit, CLK = 0
        sw      a4, BSHR(a0)            # CLK = 1
        slli    a1, a1, 1
        .endr
        .endm

        .section .bss
        .balign 4
        .global fb
        .global row_idx
fb:     .space  20                      # 5 rows x 32 columns
row_idx:.space  4                       # must directly follow fb

        .section .text
        .balign 4

# ----------------------------------------------------------------------
# led_init: clock GPIOA+GPIOC, idle levels first (OE=1 blank), then
# PC0, PC2, PA1, PA2 as push-pull outputs; clear framebuffer and row_idx
# ----------------------------------------------------------------------
        .global led_init
led_init:
        li      t0, RCC
        lw      t1, PB2PCENR(t0)
        ori     t1, t1, (IOPAEN | IOPCEN)
        sw      t1, PB2PCENR(t0)

        li      a0, GPIOC               # idle levels before the pins become
        li      t0, INIT_C              # outputs: display stays blank
        sw      t0, BSHR(a0)
        li      a1, GPIOA
        li      t0, INIT_A
        sw      t0, BSHR(a1)

        lw      t0, CFGLR(a0)           # PC0, PC2 -> 0x1 (bits 3:0, 11:8)
        li      t1, 0xFFFFF0F0
        and     t0, t0, t1
        ori     t0, t0, 0x101
        sw      t0, CFGLR(a0)

        lw      t0, CFGLR(a1)           # PA1, PA2 -> 0x1 (bits 7:4, 11:8)
        li      t1, 0xFFFFF00F
        and     t0, t0, t1
        li      t1, 0x110
        or      t0, t0, t1
        sw      t0, CFGLR(a1)

        la      t0, fb
        sw      x0, 0(t0)
        sw      x0, 4(t0)
        sw      x0, 8(t0)
        sw      x0, 12(t0)
        sw      x0, 16(t0)
        sw      x0, 20(t0)              # row_idx
        ret

# ----------------------------------------------------------------------
# led_refresh_row: shift out one row, latch, advance row_idx
# ----------------------------------------------------------------------
        .global led_refresh_row
led_refresh_row:
        li      a0, GPIOC
        li      a2, DATA_MASK
        li      a3, BIT0_WORD
        li      a4, CLK_SET
        la      a5, row_idx
        lw      t2, 0(a5)               # t2 = current row 0..4

        li      t1, GPIOA
        li      t0, OE_SET
        sw      t0, BSHR(t1)            # blank outputs -> row FET gates pulled
                                        # high, no ghosting while we shift

        li      a1, 1                   # row word: (1 << row) in bits 31..16
        sll     a1, a1, t2
        slli    a1, a1, 16
        SENDBITS 16                     # 16 clocks -> U3 (row driver)

        la      t0, fb                  # column word of this row
        slli    t1, t2, 2
        add     t0, t0, t1
        lw      a1, 0(t0)
        SENDBITS 32                     # 32 clocks -> U2 then U1 (columns)

        li      t1, GPIOA               # (also gives LE hold margin after the
        li      t0, LE_SET              #  last CLK edge)
        sw      t0, BSHR(t1)            # LE high: latch transparent
        li      t0, LE_RST
        sw      t0, BSHR(t1)            # LE low: data latched (outputs off)
        li      t0, CLK_RST
        sw      t0, BSHR(a0)            # CLK low (idle)
        li      t0, OE_RST
        sw      t0, BSHR(t1)            # OE low: outputs on

        addi    t0, t2, 1               # advance row_idx, wrap at 5
        li      t1, 5
        bne     t0, t1, 1f
        li      t0, 0
1:      sw      t0, 0(a5)
        ret
