##
# Traps (the one interrupt, the tick, is in 12-ticks.s)
##

.balign CELL
.global trap_handler
.type trap_handler, @function
# The trap handler: every exception and the NMI come here through the vector
# table at 0x0 (sixforths.s). The QingKe V2 manual (section 2.2 and the mtvec
# table) requires a 1 KiB-aligned table, and 0x0 is one; the table holds this
# handler's address, so the handler itself needs no such alignment.
# It prints 'T' followed by mcause and mepc in hex on the console (USART1),
# then hangs with all state intact for the debugger: if a trap fires, the
# terminal says why and where.
trap_handler:
    li t0, USART1_BASE
    li t2, 'T'
beacon_putc:
    lw t1, USART_STATR(t0)      # poll TXE
    andi t1, t1, USART_STATR_TXE
    beqz t1, beacon_putc
    sw t2, USART_DATAR(t0)      # send 'T'
    csrr a1, mcause             # first value to print
    li a3, 2                    # two passes: mcause, then mepc
beacon_word:
    li a2, 8                    # 8 hex nibbles per word
beacon_nibble:
    lw t1, USART_STATR(t0)
    andi t1, t1, USART_STATR_TXE
    beqz t1, beacon_nibble
    srli t2, a1, 28             # take the top nibble
    addi t2, t2, '0'            # '0'..'9'
    li t1, '9'
    ble t2, t1, beacon_digit
    addi t2, t2, 'A'-'9'-1      # 'A'..'F'
beacon_digit:
    sw t2, USART_DATAR(t0)
    slli a1, a1, 4              # move next nibble to the top
    addi a2, a2, -1
    bnez a2, beacon_nibble
    li t2, ' '                  # separator between the two values
beacon_sep:
    lw t1, USART_STATR(t0)
    andi t1, t1, USART_STATR_TXE
    beqz t1, beacon_sep
    sw t2, USART_DATAR(t0)
    csrr a1, mepc               # second value to print
    addi a3, a3, -1
    bnez a3, beacon_word
beacon_hang:
    j beacon_hang               # hang; registers/CSRs stay inspectable

# Initialize the trap and interrupt CSRs: interrupts off, the trap vector set
trap_init:
    # disable global interrupts
    csrc mstatus, 0x08  # mstatus = 0x300

    # The QingKe V2 core has no mie/mip CSRs to clear: interrupt sources are
    # gated by the PFIC, and every PFIC channel is disabled at reset.

    # set the trap vector: mtvec = 0x0 | 3, the vector table at 0x0 (see
    # sixforths.s); MODE0 = 1: entry at base + number*4, MODE1 = 1: entries
    # are addresses
    li t0, 3
    csrw mtvec, t0      # mtvec = 0x305

    ret
