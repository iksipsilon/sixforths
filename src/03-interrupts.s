##
# Interrupts
##

.balign CELL
.global interrupt_handler
.type interrupt_handler, @function
# CH32V006 PORT: two changes here.
# 1) The handler is aligned to 1 KiB. QingKe cores document coarse alignment
#    of the trap vector base (1 KiB on QingKe V4); if the V2 masks the low
#    bits of mtvec the same way, a handler at an arbitrary address makes the
#    *effective* trap target 0x000 -- i.e. _start -- so every trap would look
#    like a spontaneous reboot with a fresh banner.
# 2) Instead of a bare mret, the handler is a forensic beacon: it prints 'T'
#    followed by mcause and mepc in hex over the UART, then hangs with all
#    state intact for the debugger. If a trap fires, the terminal says why.
.balign 1024
interrupt_handler:
    li t0, UART_BASE_ADDRESS
    li t2, 'T'
beacon_putc:
    lw t1, UART_TX_STATUS(t0)   # poll TXE
    andi t1, t1, UART_TX_BIT
    beqz t1, beacon_putc
    sw t2, UART_TX_DATA(t0)     # send 'T'
    csrr a1, mcause             # first value to print
    li a3, 2                    # two passes: mcause, then mepc
beacon_word:
    li a2, 8                    # 8 hex nibbles per word
beacon_nibble:
    lw t1, UART_TX_STATUS(t0)
    andi t1, t1, UART_TX_BIT
    beqz t1, beacon_nibble
    srli t2, a1, 28             # take the top nibble
    addi t2, t2, '0'            # '0'..'9'
    li t1, '9'
    ble t2, t1, beacon_digit
    addi t2, t2, 'A'-'9'-1      # 'A'..'F'
beacon_digit:
    sw t2, UART_TX_DATA(t0)
    slli a1, a1, 4              # move next nibble to the top
    addi a2, a2, -1
    bnez a2, beacon_nibble
    li t2, ' '                  # separator between the two values
beacon_sep:
    lw t1, UART_TX_STATUS(t0)
    andi t1, t1, UART_TX_BIT
    beqz t1, beacon_sep
    sw t2, UART_TX_DATA(t0)
    csrr a1, mepc               # second value to print
    addi a3, a3, -1
    bnez a3, beacon_word
beacon_hang:
    j beacon_hang               # hang; registers/CSRs stay inspectable

# Initialize the interrupt CSRs
interrupt_init:
    # disable global interrupts
    csrc mstatus, 0x08  # mstatus = 0x300

    # CH32V006 PORT: removed `csrs mie, zero`. The QingKe V2 core does not
    # implement the mie/mip CSRs; interrupt sources are gated by the PFIC
    # peripheral instead, and every PFIC channel is disabled at reset, so
    # there is nothing to clear. Touching an unimplemented CSR could trap
    # before mtvec below is even set.

    # set interrupt handler jump address
    # (QingKe V2: mtvec[1:0] = 00 selects non-vectored mode, i.e. jump to
    # BASE; interrupt_handler is CELL-aligned so the low bits are 0 already)
    la t0, interrupt_handler
    csrw mtvec, t0      # mtvec = 0x305

    ret
