##
# Flash: the FPEC routines, the source lines and the user flash page words
# (CH32V006 PORT)
#
# Source lines: LINES_BASE..LINES_TOP holds 160 slots of 64 bytes. A slot is
# the text of one line (up to 63 characters), a newline, then unused bytes
# that stay 0xFF; a slot that was never written is all 0xFF. `load` points
# the input-source switch in uart_get at a range of lines, which are then
# interpreted as if they were typed; 0xFF bytes are skipped. Line 0 is
# loaded at boot.
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
# Source lines
##

.balign CELL
# the slot of a line
# arguments: a0 = line number
# returns: a0 = address of its slot; jumps to the error handler unless the
# number is 0 ... LINES-1
# clobbers: t0
line_addr:
    li t0, LINES
    bgeu a0, t0, err_error
    slli a0, a0, 6              # * LINE_SIZE
    li t0, LINES_BASE
    add a0, a0, t0
    ret

# line ( n -- addr )    Address of the 64-byte slot of line n (0 ... 159)
defcode "line",4,,LINE
    checkunderflow 0
    lw a0, 0(s0)
    call line_addr              # (clobbers t0)
    sw a0, 0(s0)
    NEXT

# p ( n -- )           Put the rest of the input line into line n, in flash
# at once: `20 p : sq dup * ;`. The text may be 63 characters long; no text
# makes an empty line. The page that holds the line (4 lines) is copied to
# PAGEBUF, the slot is rebuilt there (text, newline, 0xFF), and the page is
# erased, programmed and read back. Errors with ? and writes nothing if n is
# not 0 ... 159 or the text is too long; `? flash` if the read-back differs.
defcode "p",1,,PUT
    checkunderflow 0
    POP a0
    call line_addr              # a0 = the slot (clobbers t0)
    # the text: from >in to the end of the line, as `parse` does it
    li t2, TIB_BOTTOM
    li a4, var_TOIN
    lw a1, 0(a4)
    add a1, a1, t2
    lbu t0, 0(a1)
    li t1, CHAR_SPACE
    bne t0, t1, put_start
    addi a1, a1, 1              # skip the one space after `p`
put_start:
    mv a2, a1                   # a1 = start of the text
    li a5, TIB_TOP
put_scan:
    bgeu a2, a5, put_eol        # never scan past the TIB
    lbu t0, 0(a2)
    beqz t0, put_eol            # the TIB is zero-filled beyond the line
    addi a2, a2, 1
    j put_scan
put_eol:
    sub t0, a2, t2
    sw t0, 0(a4)                # >in = end of the line: the text is not interpreted
    sub a2, a2, a1              # a2 = length...
    beqz a2, put_len
    addi a2, a2, -1             # ...without the space the newline became
put_len:
    li t0, LINE_SIZE-1
    bgtu a2, t0, err_error      # room for 63 characters and the newline
    # copy the page of the slot to PAGEBUF
    andi a3, a0, -FLASH_PAGE    # a3 = page address
    mv t2, a3
    li a4, PAGEBUF
    addi t1, a3, FLASH_PAGE     # t1 = end of the page
put_stage:
    lw t0, 0(t2)
    sw t0, 0(a4)
    addi t2, t2, CELL
    addi a4, a4, CELL
    bne t2, t1, put_stage
    # the slot in the copy: all 0xFF, then the text and a newline
    sub a4, a0, a3
    li t0, PAGEBUF
    add a4, a4, t0              # a4 = the slot in PAGEBUF
    mv t2, a4
    addi t1, a4, LINE_SIZE
    li t0, -1
put_blank:
    sw t0, 0(t2)
    addi t2, t2, CELL
    bne t2, t1, put_blank
put_text:
    beqz a2, put_newline
    lbu t0, 0(a1)
    sb t0, 0(a4)
    addi a1, a1, 1
    addi a4, a4, 1
    addi a2, a2, -1
    j put_text
put_newline:
    li t0, CHAR_NEWLINE
    sb t0, 0(a4)
    # erase, program, read back
    mv a0, a3
    call fpage_erase            # a0 = page (clobbers t0, t1)
    li a2, PAGEBUF
    call fpage_prog             # a0 = page, a2 = source (clobbers t0-t2, a2-a4)
    li a4, PAGEBUF
    addi a3, a0, FLASH_PAGE     # a3 = end of the page
put_verify:
    lw t1, 0(a0)
    lw t2, 0(a4)
    bne t1, t2, err_flash       # the flash did not take it
    addi a0, a0, CELL
    addi a4, a4, CELL
    bne a0, a3, put_verify
    NEXT

# load ( a b -- )       Interpret lines a to b as if they were typed. They are
# read when the current input line is finished, so anything after `load` on
# its line runs first: put it last. A `load` in a loaded line replaces the
# range (it does not come back). An error abandons the rest.
defcode "load",4,,LOAD
    checkunderflow CELL
    POP a0                      # b
    POP a1                      # a
    bltu a0, a1, err_error      # nothing to load backwards
    call line_addr              # (clobbers t0)
    addi a2, a0, LINE_SIZE      # a2 = the end of line b
    mv a0, a1
    call line_addr
    li t0, var_SRC
    sw a0, 0(t0)
    sw a2, var_SRCEND-var_SRC(t0)
    NEXT

# wipe ( -- )           Erase all the lines
defcode "wipe",4,,WIPE
    li a3, LINES_BASE     # a3 (Z) survives the calls below
wipe_loop:
    li t0, LINES_TOP
    bgeu a3, t0, wipe_done
    mv a0, a3
    call fpage_erase    # erase one 256-byte page (clobbers t0, t1, ra)
    addi a3, a3, FLASH_PAGE
    j wipe_loop
wipe_done:
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
