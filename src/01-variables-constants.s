##
# Variables and constants
##

.equ FORTH_VERSION, 3

##
# Memory map
##

# DSP, RSP, TIB stacks grow downward from the top of memory
.equ DSP_TOP, RAM_BASE + RAM_SIZE       # address of top of data stack
.equ RSP_TOP, DSP_TOP - STACK_SIZE      # address of top of return stack
.equ TIB_TOP, RSP_TOP - STACK_SIZE      # address of top of terminal buffer
.equ TIB_BOTTOM, TIB_TOP - STACK_SIZE   # address of bottom of terminal buffer

# CH32V006 PORT: room kept free under the data stack for one interrupt frame.
# With the hardware prologue (HPE) on, the QingKe V2 saves ra, t0-t2 and
# a0-a5 at sp when an interrupt is taken: 48 bytes (processor manual 3.4).
# The data stack therefore holds (STACK_SIZE - IRQ_FRAME) / CELL = 52 cells.
# One frame only: interrupts must not nest.
.equ IRQ_FRAME, 48

# variables
.equ var_STATE, TIB_BOTTOM - CELL       # 1 CELL for STATE variable
.equ var_TOIN, var_STATE - CELL         # 1 CELL for TOIN variable (looks into TIB)
.equ var_HERE, var_TOIN - CELL          # 1 CELL for HERE variable
.equ var_LATEST, var_HERE - CELL        # 1 CELL for LATEST variable
.equ NOOP, var_LATEST - CELL            # 1 CELL for NOOP variable
# CH32V006 PORT: source-replay log variables (see 12-flash-log.s)
.equ LOGEN, NOOP - CELL                 # 1 CELL: logging enabled flag (0 = off)
.equ LOGPND, LOGEN - CELL               # 1 CELL: pending byte count in LOGBUF
.equ LOGSRC, LOGPND - CELL              # 1 CELL: replay pointer (0 = UART, -1 = armed)
.equ LOGEND, LOGSRC - CELL              # 1 CELL: append frontier in the flash log
# CH32V006 PORT: variables of the number output words. They are RAM cells here
# because the words that use them (10-forth-words.s) live in flash.
.equ var_BASE, LOGEND - CELL            # 1 CELL: number base for . u. # (see base)
.equ var_HLD, var_BASE - CELL           # 1 CELL: <# ... #> build pointer (see hld)
# CH32V006 PORT: vocabularies. A vocabulary is known by the address of its head
# cell, the cell that holds the header of its newest word. FORTH's head cell is
# var_LATEST; the head cell of a vocabulary made with `vocabulary` is the first
# data cell of that word.
.equ var_CONTEXT, var_HLD - CELL        # 1 CELL: head cell of the vocabulary searched first
.equ var_CURRENT, var_CONTEXT - CELL    # 1 CELL: head cell of the vocabulary definitions go to
.equ var_VOCLINK, var_CURRENT - CELL    # 1 CELL: newest vocabulary (its link cell), 0 = none
.equ PAD, var_VOCLINK - (CELL * 64)     # 64 CELLS between var_VOCLINK and PAD
# CH32V006 PORT: pending batch buffer for the log. Lines of a multi-line
# definition are held here and committed to flash only when a line ends with
# STATE = 0, so a definition reaches the log whole or not at all.
.equ LOGBUF_SIZE, 256
.equ LOGBUF, PAD - LOGBUF_SIZE

# dictionary grows upward from the RAM base address
.equ FORTH_SIZE, LOGBUF - RAM_BASE      # remaining memory for Forth

##
# Flash layout (CH32V006 PORT)
##

# The kernel occupies the bottom 16 KiB (enforced by linker.ld LENGTH).
# Above it, a 10 KiB source-replay log: successfully interpreted lines are
# appended as plain text and re-interpreted at boot. Erased flash (0xFF) is
# the natural end-of-log marker; the log never contains a 0xFF byte.
# The regions use the 0x08000000 flash base: the FPEC takes such addresses
# for program/erase, and the same addresses read back via the flash alias.
# The space above LOG_TOP is reserved for the phonebook and SMS slot stores.
.equ FLASH_ALIAS, 0x08000000
.equ LOG_BASE, FLASH_ALIAS + 0x4000     # bottom of the source-replay log
.equ LOG_TOP, FLASH_ALIAS + 0x6800      # top of the log (10 KiB region)
# Above the log: flash for the application's own data (call log, settings),
# written a 256-byte page at a time with fpage-erase / fpage-prog. Those two
# words refuse any address outside USER_FLASH..FLASH_TOP, so they cannot
# damage the kernel or the source log.
.equ USER_FLASH, LOG_TOP                # first page of the user flash
.equ FLASH_TOP, FLASH_ALIAS + 0xF800    # end of the 62 KiB code flash

##
# Interpreter constants
##

.equ CHAR_NEWLINE, '\n'         # newline character 0x0A
.equ CHAR_CARRIAGE, '\r'        # carriage return character 0x0D
.equ CHAR_SPACE, ' '            # space character 0x20
.equ CHAR_BACKSPACE, '\b'       # backspace character 0x08
.equ CHAR_COMMENT, '\\'         # backslash character 0x5C
.equ CHAR_COMMENT_OPARENS, '('  # open parenthesis character 0x28
.equ CHAR_COMMENT_CPARENS, ')'  # close parenthesis character 0x29
.equ CHAR_MINUS, '-'            # minus character 0x2D

##
# Flags
###

# CH32V006 PORT: jonesforth-style headers. The word name is stored in the
# header as a counted string: one flags+length byte, then the name bytes,
# then zero-padding up to a CELL boundary, then the code field. The flags
# live in the top bits of the count byte (fig-Forth/jonesforth layout), so
# names are limited to 31 characters.
.equ F_IMMEDIATE, 0x80          # immediate flag bit in the flags+length byte
.equ F_HIDDEN, 0x20             # hidden flag bit in the flags+length byte
.equ F_LENMASK, 0x1f            # name length mask (max name length 31)
