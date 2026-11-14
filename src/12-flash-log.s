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
# Flash physics: the V006 erases and programs whole 256-byte pages (FTER,
# FTPG). An append rewrites each page it touches: the page is copied into
# the TIB (free at commit time: err_ok zero-fills it right after), the new
# bytes are merged in, the page is erased unless it already reads all 0xFF,
# programmed from the TIB and read back. A power cut between erase and
# program loses that page's earlier lines; replay then stops at the damage
# (PD4 skips it). Batches stay padded to even length (a space before the
# final newline) so log_scan can look for an erased halfword. All ops run
# from flash: the core stalls while the FPEC is busy, which is fine.
##

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
# fast-program one 256-byte page from RAM; the page must be erased
# (reference manual 18.4.5: FTPG, BUFRST, 64 x (word store + BUFLOAD),
# FLASH_ADDR, STRT)
# arguments: a0 = page address (0x08...-based, 256-byte aligned),
#            a2 = source in RAM (CELL-aligned, 256 bytes)
# clobbers: t0, t1, t2, a2, a3, a4
fpage_prog:
    li t0, FLASH_R_BASE
fpage_prog_bsy0:
    lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, fpage_prog_bsy0
    li t1, FLASH_CTLR_FTPG
    sw t1, FLASH_CTLR(t0)       # fast page programming mode on
    li t1, FLASH_CTLR_FTPG | FLASH_CTLR_BUFRST
    sw t1, FLASH_CTLR(t0)       # clear the page buffer
fpage_prog_bsy1:
    lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, fpage_prog_bsy1
    mv a3, a0                   # a3 = flash address of the next word
    li a4, FLASH_PAGE / CELL    # a4 = words left to load (64)
fpage_prog_load:
    lw t2, 0(a2)                # next word from RAM
    sw t2, 0(a3)                # latch it at its flash address
    li t1, FLASH_CTLR_FTPG | FLASH_CTLR_BUFLOAD
    sw t1, FLASH_CTLR(t0)       # load it into the page buffer
fpage_prog_bsy2:
    lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, fpage_prog_bsy2
    addi a2, a2, CELL
    addi a3, a3, CELL
    addi a4, a4, -1
    bnez a4, fpage_prog_load
    sw a0, FLASH_ADDR(t0)       # page address
    li t1, FLASH_CTLR_FTPG | FLASH_CTLR_STRT
    sw t1, FLASH_CTLR(t0)       # start the page programming
fpage_prog_bsy3:
    lw t1, FLASH_STATR(t0)
    andi t1, t1, FLASH_STATR_BSY
    bnez t1, fpage_prog_bsy3
    sw zero, FLASH_CTLR(t0)     # fast page programming mode off
    ret

.balign CELL
# fast-erase one 256-byte flash page
# arguments: a0 = page address (0x08...-based, 256-byte aligned)
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
    addi sp, sp, -2*CELL        # two cells on the machine stack: ra (nested
    sw ra, CELL(sp)             # calls below) and, at 0(sp), the append frontier

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
    # make it even-length (log_scan looks for an erased halfword):
    # final '\n' -> ' ' '\n'
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
    lw a2, 0(t0)                # a2 = append frontier (destination)
    sw a2, 0(sp)                # kept at 0(sp) while the pages are written
    add a4, a2, t1
    li a5, LOG_TOP
    bgtu a4, a5, log_commit_off
    mv gp, t1                   # gp = bytes left to write (even, > 0)
    li a1, LOGBUF               # a1 = next source byte
log_commit_page:
    # stage the page holding the frontier in the TIB, and AND its words
    # together: -1 means the page is still fully erased
    lw a2, 0(sp)                # a2 = frontier
    andi a0, a2, -FLASH_PAGE    # a0 = page address
    mv a3, a0
    li a4, TIB_BOTTOM
    li a5, -1
    addi t1, a0, FLASH_PAGE     # t1 = end of the page
log_commit_stage:
    lw t2, 0(a3)
    sw t2, 0(a4)
    and a5, a5, t2
    addi a3, a3, CELL
    addi a4, a4, CELL
    bne a3, t1, log_commit_stage
    # merge in the batch bytes that fall into this page
    sub a3, a2, a0              # a3 = frontier offset in the page
    li a4, TIB_BOTTOM
    add a4, a4, a3
log_commit_merge:
    lbu t2, 0(a1)
    sb t2, 0(a4)
    addi a1, a1, 1
    addi a4, a4, 1
    addi a3, a3, 1
    addi gp, gp, -1
    beqz gp, log_commit_tail
    li t1, FLASH_PAGE
    bltu a3, t1, log_commit_merge
log_commit_tail:
    add t1, a0, a3
    sw t1, 0(sp)                # the frontier is now after the merged bytes
    # everything after the new bytes stays erased
    li t1, FLASH_PAGE
    li t2, 0xFF
log_commit_fill:
    bgeu a3, t1, log_commit_write
    sb t2, 0(a4)
    addi a4, a4, 1
    addi a3, a3, 1
    j log_commit_fill
log_commit_write:
    li t1, -1
    beq a5, t1, log_commit_prog # page reads all 0xFF: no erase needed
    call fpage_erase            # a0 = page (clobbers t0, t1)
log_commit_prog:
    li a2, TIB_BOTTOM
    call fpage_prog             # a0 = page, a2 = TIB (clobbers t0-t2, a2-a4)
    # read the page back: it must match the staged copy
    mv a3, a0
    li a4, TIB_BOTTOM
    addi a5, a0, FLASH_PAGE     # a5 = end of the page
log_commit_verify:
    lw t1, 0(a3)
    lw t2, 0(a4)
    bne t1, t2, log_commit_off  # the flash did not take it: logging off
    addi a3, a3, CELL
    addi a4, a4, CELL
    bne a3, a5, log_commit_verify
    bnez gp, log_commit_page    # the batch continues on the next page
log_commit_done:
    lw t1, 0(sp)
    li t0, LOGEND
    sw t1, 0(t0)                # advance the frontier
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
    lw ra, CELL(sp)             # restore ra, drop the two cells
    addi sp, sp, 2*CELL
    ret

msg_logoff: .ascii "  ? log off\n"

##
# Log words
##

# +log ( -- )           Enable logging of successful lines to the flash log
defcode "+log",4,,PLOG
    li t0, LOGEN
    li t1, 1
    sw t1, 0(t0)
    NEXT

# -log ( -- )           Disable logging (this line itself is not logged)
defcode "-log",4,,MLOG
    li t0, LOGEN
    sw zero, 0(t0)
    NEXT

##
# Flash page words for the application's data (above the log)
##

.balign CELL
# check a page address for the two words below
# arguments: a0 = any address in the page
# returns: a0 = the page address (rounded down to 256 bytes); jumps to the
# error handler unless the page lies in USER_FLASH..FLASH_TOP
# clobbers: t0
flash_user_page:
    andi a0, a0, -FLASH_PAGE
    li t0, USER_FLASH
    bltu a0, t0, err_error
    li t0, FLASH_TOP
    bgeu a0, t0, err_error
    ret

# fpage-erase ( page -- )   Erase one 256-byte page of the user flash (it then
# reads 0xFF). page is a 0x08...... address, e.g. 0x0800E800. Takes about 3 ms,
# during which the core stands still. Errors with ? outside the user flash.
defcode "fpage-erase",11,,FPAGEERASE
    checkunderflow 0
    POP a0
    call flash_user_page
    call fpage_erase            # (clobbers t0, t1)
    NEXT

# fpage-prog ( src page -- )   Program one 256-byte page of the user flash
# from the 256 bytes at src (RAM, CELL-aligned). The page must be erased:
# flash can only clear bits, so the word checks and errors with ? instead of
# writing a mix of old and new. Errors too if src is unaligned or the page is
# outside the user flash. To change part of a page: copy it to RAM, change
# the copy, fpage-erase, fpage-prog. Compare afterwards with  s=  if needed.
defcode "fpage-prog",10,,FPAGEPROG
    checkunderflow CELL
    POP a0                      # page
    POP a2                      # source
    andi t0, a2, CELL-1
    bnez t0, err_error          # the source must be CELL-aligned
    call flash_user_page
    mv a3, a0                   # the page must read all 0xFF
    addi a4, a0, FLASH_PAGE
fpageprog_blank:
    lw t1, 0(a3)
    addi t1, t1, 1              # 0xFFFFFFFF + 1 = 0
    bnez t1, err_error
    addi a3, a3, CELL
    bne a3, a4, fpageprog_blank
    call fpage_prog             # a0 = page, a2 = source (clobbers t0-t2, a2-a4)
    NEXT

# wipe ( -- )           Erase the whole log region and disable logging
defcode "wipe",4,,WIPE
    li t0, LOGEN
    sw zero, 0(t0)      # logging off (so this line is never logged)
    li t0, LOGPND
    sw zero, 0(t0)      # drop any pending batch
    li a3, LOG_BASE     # a3 (Z) survives the calls below
wipe_loop:
    li t0, LOG_TOP
    bgeu a3, t0, wipe_done
    mv a0, a3
    call fpage_erase    # erase one 256-byte page (clobbers t0, t1, ra)
    addi a3, a3, FLASH_PAGE
    j wipe_loop
wipe_done:
    li t0, LOGEND
    li t1, LOG_BASE
    sw t1, 0(t0)        # the frontier is back at the bottom
    NEXT
