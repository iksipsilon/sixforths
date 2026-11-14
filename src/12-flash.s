##
# Flash: the FPEC routines, the source region and the user flash page words
# (CH32V006 PORT)
#
# The source region (LOG_BASE..LOG_TOP) holds plain text that is interpreted
# at boot through the input-source switch in uart_get. Erased flash (0xFF)
# ends it. Nothing writes the region at the moment: the appending log is
# gone, and the line words (p list load) are not in yet. `wipe` erases it.
#
# Flash physics: the V006 erases and programs whole 256-byte pages (FTER,
# FTPG). All ops run from flash: the core stalls while the FPEC is busy,
# which is fine.
##

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

# wipe ( -- )           Erase the whole source region
defcode "wipe",4,,WIPE
    li a3, LOG_BASE     # a3 (Z) survives the calls below
wipe_loop:
    li t0, LOG_TOP
    bgeu a3, t0, wipe_done
    mv a0, a3
    call fpage_erase    # erase one 256-byte page (clobbers t0, t1, ra)
    addi a3, a3, FLASH_PAGE
    j wipe_loop
wipe_done:
    NEXT
