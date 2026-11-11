##
# Source-replay log (CH32V006 PORT)
#
# Persistence model: successfully interpreted lines are appended as plain
# text to a flash region (LOG_BASE..LOG_TOP) and re-interpreted at boot
# through the input-source switch in uart_get. Erased flash (0xFF) is the
# end-of-log marker; the log never contains a 0xFF byte.
#
# Logging is definition-atomic: while a colon definition is open (STATE=1),
# its lines accumulate in the LOGBUF pending batch and reach flash only when
# a line ends back in interpret state. Any error resets the interpreter,
# which drops the pending batch, so a definition is logged whole or not at
# all and the log can only ever contain lines that interpreted cleanly.
#
# Words: +log (enable logging), -log (disable), wipe (erase the log region
# and disable logging). A line is logged iff LOGEN=1 when the line
# completes, so "-log" and "wipe" never log themselves, while "+log" does
# (harmless on replay: appends are suppressed while replaying).
#
# Flash physics: appends use standard halfword (16-bit) programming into
# erased flash, so batches are padded to even length (a space before the
# final newline). wipe uses the fast 64-byte page erase. Both ops execute
# from flash: the core stalls while the FPEC is busy, which is fine.
##

.section .text            # CH32V006 PORT: defcode leaves .rodata active;
                          # switch back so this file's code lands in .text
.balign CELL
# wait until the FPEC is idle
# clobbers: t0 (returns FLASH_R_BASE in t0), t1
flash_wait:
    li t0, FLASH_R_BASE
flash_wait_loop:
    lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, flash_wait_loop
    ret

.balign CELL
# unlock the FPEC for programming (KEYR) and fast erase (MODEKEYR).
# Called once at boot; the FPEC stays unlocked (this is a dev system whose
# whole point is self-programming).
# clobbers: t0, t1
flash_unlock:
    li t0, FLASH_R_BASE
    li t1, FLASH_KEY1
    sw t1, FLASH_KEYR(t0)
    li t1, FLASH_KEY2
    sw t1, FLASH_KEYR(t0)
    li t1, FLASH_KEY1
    sw t1, FLASH_MODEKEYR(t0)
    li t1, FLASH_KEY2
    sw t1, FLASH_MODEKEYR(t0)
    ret

.balign CELL
# program one halfword into erased flash (standard PG mode)
# arguments: a0 = flash address (0x08...-based, halfword-aligned),
#            a2 = halfword value
# clobbers: t0, t1
fh_prog:
    li t0, FLASH_R_BASE
fh_prog_bsy0:
    lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, fh_prog_bsy0
    li t1, FLASH_CTLR_PG
    sw t1, FLASH_CTLR(t0)       # programming mode on
    sh a2, 0(a0)                # the program operation itself
fh_prog_bsy1:
    lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, fh_prog_bsy1
    sw zero, FLASH_CTLR(t0)     # programming mode off
    ret

.balign CELL
# fast-erase one 64-byte flash page
# arguments: a0 = page address (0x08...-based, 64-byte aligned)
# clobbers: t0, t1
fpage_erase:
    li t0, FLASH_R_BASE
fpage_erase_bsy0:
    lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, fpage_erase_bsy0
    li t1, FLASH_CTLR_FTER
    sw t1, FLASH_CTLR(t0)       # fast page erase mode on
    sw a0, FLASH_ADDR(t0)       # page address
    li t1, FLASH_CTLR_FTER | FLASH_CTLR_STRT
    sw t1, FLASH_CTLR(t0)       # start the erase
fpage_erase_bsy1:
    lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, fpage_erase_bsy1
    sw zero, FLASH_CTLR(t0)     # fast page erase mode off
    ret

.balign CELL
# find the append frontier: the first erased halfword in the log region.
# Appends are always even-length and never write 0xFF bytes, so the first
# 0xFFFF halfword is the frontier. Called once at boot.
# clobbers: t0, t1, t2, a0
log_scan:
    li t0, LOG_BASE
    li t1, LOG_TOP
    li a0, 0xFFFF
log_scan_loop:
    bgeu t0, t1, log_scan_done
    lhu t2, 0(t0)               # halfword-aligned: LOG_BASE is even
    beq t2, a0, log_scan_done
    addi t0, t0, 2
    j log_scan_loop
log_scan_done:
    li t1, LOGEND
    sw t0, 0(t1)
    ret

.balign CELL
# commit hook, called from err_ok with the completed line still in the TIB.
# Appends the line to the pending batch; flushes the batch to flash when the
# line ends in interpret state. See the file header for the full policy.
log_commit:
    addi s0, s0, -CELL          # spill ra to the return stack (nested calls
    sw ra, 0(s0)                # below; one unchecked cell, like uart_print)

    # never append while replaying: the source already IS the log
    li t0, LOGSRC
    lw t1, 0(t0)
    bnez t1, log_commit_drop
    # logging off: drop any pending batch too
    li t0, LOGEN
    lw t1, 0(t0)
    beqz t1, log_commit_drop
    # skip blank lines (a lone space left by the converted newline)
    li t0, var_TOIN
    lw t1, 0(t0)                # t1 = line length in the TIB
    li t0, 1
    bleu t1, t0, log_commit_exit

    # append TIB[0..len) + '\n' to the pending batch
    li t0, LOGPND
    lw t2, 0(t0)                # t2 = current pending count
    add a4, t2, t1
    addi a4, a4, 1              # new count including the newline
    li a5, LOGBUF_SIZE - 1      # keep one byte spare for the even-length pad
    bgtu a4, a5, log_commit_off # definition too large for one batch
    li a0, TIB_BOTTOM
    li a1, LOGBUF
    add a1, a1, t2
log_commit_copy:
    lbu a2, 0(a0)
    sb a2, 0(a1)
    addi a0, a0, 1
    addi a1, a1, 1
    addi t1, t1, -1
    bnez t1, log_commit_copy
    li a2, CHAR_NEWLINE
    sb a2, 0(a1)                # terminate the line
    sw a4, 0(t0)                # LOGPND = new count (t0 is still LOGPND)

    # hold the batch while a colon definition is open
    li t0, var_STATE
    lw t1, 0(t0)
    bnez t1, log_commit_exit

    # === commit the batch ===
    # make it even-length for halfword programming: final '\n' -> ' ' '\n'
    li t0, LOGPND
    lw t1, 0(t0)
    andi a2, t1, 1
    beqz a2, log_commit_even
    li a4, LOGBUF
    add a4, a4, t1
    li a2, CHAR_SPACE
    sb a2, -1(a4)
    li a2, CHAR_NEWLINE
    sb a2, 0(a4)
    addi t1, t1, 1
log_commit_even:
    # room check against the top of the log region
    li t0, LOGEND
    lw tp, 0(t0)                # tp = append frontier (destination)
    add a4, tp, t1
    li a5, LOG_TOP
    bgtu a4, a5, log_commit_off
    mv gp, t1                   # gp = remaining bytes (even)
    li a1, LOGBUF               # a1 = source
log_commit_flush:
    beqz gp, log_commit_done
    lbu a2, 0(a1)               # build the little-endian halfword
    lbu a3, 1(a1)
    slli a3, a3, 8
    or a2, a2, a3
    mv a0, tp
    call fh_prog                # program it (clobbers t0, t1)
    addi tp, tp, 2
    addi a1, a1, 2
    addi gp, gp, -2
    j log_commit_flush
log_commit_done:
    li t0, LOGEND
    sw tp, 0(t0)                # advance the frontier
    j log_commit_drop

log_commit_off:
    # batch overflow or log region full: drop the batch, disable logging,
    # and say so - the line was NOT saved
    li t0, LOGEN
    sw zero, 0(t0)
    la a1, msg_logoff
    addi a2, a1, 12
    call uart_print
log_commit_drop:
    li t0, LOGPND
    sw zero, 0(t0)
log_commit_exit:
    lw ra, 0(s0)                # restore ra from the return stack
    addi s0, s0, CELL
    ret

msg_logoff: .ascii "  ? log off\n"

##
# Log words
##

# +log ( -- )           Enable logging of successful lines to the flash log
defcode "+log", PLOG, WORDS
    li t0, LOGEN
    li t1, 1
    sw t1, 0(t0)
    NEXT

# -log ( -- )           Disable logging (this line itself is not logged)
defcode "-log", MLOG, PLOG
    li t0, LOGEN
    sw zero, 0(t0)
    NEXT

# wipe ( -- )           Erase the whole log region and disable logging
defcode "wipe", WIPE, MLOG
    li t0, LOGEN
    sw zero, 0(t0)      # logging off (so this line is never logged)
    li t0, LOGPND
    sw zero, 0(t0)      # drop any pending batch
    li a3, LOG_BASE     # a3 (Z) survives the calls below
wipe_loop:
    li t0, LOG_TOP
    bgeu a3, t0, wipe_done
    mv a0, a3
    call fpage_erase    # erase one 64-byte page (clobbers t0, t1, ra)
    addi a3, a3, 64
    j wipe_loop
wipe_done:
    li t0, LOGEND
    li t1, LOG_BASE
    sw t1, 0(t0)        # the frontier is back at the bottom
    NEXT
