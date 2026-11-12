##
# Modem: USART2, received through DMA into a ring (CH32V006 PORT)
#
# USART2 runs on PD2 (TX, QFN pin 16) / PD3 (RX, pin 17) at MODEM_BAUD. DMA1
# channel 7 copies every byte it receives into MRING (01-variables-
# constants.s), round and round, without the core: it kept every byte while
# the core stood still for 16 flash page erases (CLAUDE.md, phase 2 step 3).
# No interrupt. The channel counts down from MRING_SIZE and reloads, so the
# write offset is (MRING_SIZE - DMA_CNTR7) and (MRING_SIZE - 1); var_MRD is the
# read offset, and equal offsets mean "nothing new".
# If the program falls a whole ring behind, the DMA overwrites bytes not yet
# read, and no error says so: at 115200 baud the 256 bytes last 22 ms.
##

.text
.balign CELL
# set up the clocks, the PD2/PD3 remap, DMA channel 7, USART2 and the pins.
# Called from boot. After `reboot` the channel and USART2 are still running,
# so both are switched off first; bytes not yet read are dropped.
# clobbers: t0, t1, t2
modem_init:
    li t0, RCC_BASE
    lw t1, RCC_HBPCENR(t0)
    ori t1, t1, RCC_DMA1EN
    sw t1, RCC_HBPCENR(t0)      # DMA1 clock on
    lw t1, RCC_PB2PCENR(t0)
    li t2, RCC_USART2EN | RCC_AFIOEN
    or t1, t1, t2
    sw t1, RCC_PB2PCENR(t0)     # USART2 and AFIO clocks on (port D's is on already)

    li t0, AFIO_PCFR1
    lw t1, 0(t0)
    li t2, ~AFIO_USART2_RM
    and t1, t1, t2
    li t2, AFIO_USART2_PD2_PD3
    or t1, t1, t2
    sw t1, 0(t0)                # USART2_RM = 011: TX on PD2, RX on PD3

    li t0, USART2_BASE
    sw zero, USART_CTLR1(t0)    # USART2 off while it is set up

    # the ring first, so that no received byte goes anywhere else
    li t0, DMA1_BASE
    sw zero, DMA_CFGR7(t0)      # channel off: CNTR7 can only be written then
    li t1, USART2_BASE + USART_DATAR
    sw t1, DMA_PADDR7(t0)       # from USART2's data register
    li t1, MRING
    sw t1, DMA_MADDR7(t0)       # into the ring
    li t1, MRING_SIZE
    sw t1, DMA_CNTR7(t0)        # MRING_SIZE bytes, then round again
    li t1, DMA_CFGR_MINC | DMA_CFGR_CIRC | DMA_CFGR_EN
    sw t1, DMA_CFGR7(t0)        # channel on
    li t0, var_MRD
    sw zero, 0(t0)              # nothing read yet: the write offset is 0 too
    li t0, var_MTIMEOUT
    li t1, 1000
    sw t1, 0(t0)                # mkey waits up to 1 s for a byte

    li t0, USART2_BASE
    li t1, (CPU_FREQ / MODEM_BAUD)
    sw t1, USART_BRR(t0)        # 24 MHz / 115200 = 208 (as for USART1 in uart_init)
    li t1, USART_CTLR3_DMAR
    sw t1, USART_CTLR3(t0)      # received bytes go to DMA channel 7
    li t1, USART_CTLR1_UE | USART_CTLR1_TE | USART_CTLR1_RE
    sw t1, USART_CTLR1(t0)      # on; CTLR2 keeps its reset value (1 stop bit)

    # the pins last, so TX is already idle high when PD2 starts driving it
    li t0, GPIOD_BASE
    li t1, (1 << 3)
    sw t1, GPIOD_BSHR(t0)       # PD3 output latch = 1: pull-up, not pull-down (7.3.1.3)
    lw t1, 0x00(t0)             # GPIOD_CFGLR (7.3.1.1): per pin CNF[1:0], reserved, MODE
    li t2, ~((0xf << (4*2)) | (0xf << (4*3)))
    and t1, t1, t2
    li t2, (0b1001 << (4*2)) | (0b1000 << (4*3))
    or t1, t1, t2               # PD2: CNF = 10 alternate push-pull, MODE = 1 output;
    sw t1, 0x00(t0)             # PD3: CNF = 10 input with pull-up, MODE = 0 input
    ret

# mkey? ( -- flag )     True if the modem has sent a byte that mkey has not read
defcode "mkey?",5,,MKEYQ
    li a1, DMA1_BASE
    lw a2, DMA_CNTR7(a1)
    li a3, MRING_SIZE
    sub a2, a3, a2
    andi a2, a2, MRING_SIZE-1   # a2 = write offset
    li a1, var_MRD
    lw a3, 0(a1)                # a3 = read offset
    sub a2, a2, a3
    snez a2, a2
    neg a2, a2                  # -1 if they differ, else 0
    PUSH a2
    NEXT

# mkey ( -- c | -1 )    The next byte from the modem. Waits at most mtimeout ms
# for one (counting SysTick milliseconds like ms; mtimeout <= 0 does not wait)
# and gives -1 if none came. No byte is -1, so test the result with 0< .
defcode "mkey",4,,MKEY
    li a1, var_MTIMEOUT
    lw a1, 0(a1)                # a1 = milliseconds still to wait
    li a2, STK_BASE
    lw a3, STK_CNTL(a2)         # a3 = the count when the current millisecond began
mkey_poll:
    li t1, DMA1_BASE
    lw t1, DMA_CNTR7(t1)
    li t2, MRING_SIZE
    sub t1, t2, t1
    andi t1, t1, MRING_SIZE-1   # t1 = write offset
    li t2, var_MRD
    lw a4, 0(t2)                # a4 = read offset
    bne t1, a4, mkey_take       # a byte is waiting
    blez a1, mkey_none          # waited long enough (signed, like ms)
    lw a5, STK_CNTL(a2)
    sub a5, a5, a3              # ticks into this millisecond
    li t1, STK_TICKS_PER_MS
    bltu a5, t1, mkey_poll
    add a3, a3, t1              # the next millisecond begins exactly 3000 ticks later
    addi a1, a1, -1
    j mkey_poll
mkey_take:
    li t1, MRING
    add t1, t1, a4
    lbu a5, 0(t1)               # the byte
    addi a4, a4, 1
    andi a4, a4, MRING_SIZE-1
    sw a4, 0(t2)                # one further (t2 = var_MRD)
    PUSH a5
    NEXT
mkey_none:
    li a5, -1
    PUSH a5
    NEXT

# memit ( c -- )        Send the low byte of c to the modem. Waits only for
# USART2's data register, which frees within one byte time (87 us at 115200).
defcode "memit",5,,MEMIT
    checkunderflow 0
    POP a1
    andi a1, a1, 0xFF
    li a2, USART2_BASE
memit_wait:
    lw a3, USART_STATR(a2)
    andi a3, a3, USART_STATR_TXE
    beqz a3, memit_wait
    sw a1, USART_DATAR(a2)
    NEXT

# mtimeout ( -- addr )  Variable: how many ms mkey waits for a byte (1000 at boot)
defcode "mtimeout",8,,MTIMEOUT
    li t1, var_MTIMEOUT
    PUSH t1
    NEXT
