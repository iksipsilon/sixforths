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

# variables
# CH32V006 PORT: they sit under the TIB, above the machine stack (they were
# below it). Nothing checks sp on the chip, so a machine stack that grew too
# far would have overwritten STATE, TOIN, HERE and LATEST; now it runs into
# PAD. The TIB above them is filled upwards and backspace stops at its start.
# Upstream's NOOP cell is gone: nothing used it.
.equ var_STATE, TIB_BOTTOM - CELL       # 1 CELL for STATE variable
.equ var_TOIN, var_STATE - CELL         # 1 CELL for TOIN variable (looks into TIB)
.equ var_HERE, var_TOIN - CELL          # 1 CELL for HERE variable
.equ var_LATEST, var_HERE - CELL        # 1 CELL for LATEST variable
# CH32V006 PORT: source-replay log variables (see 12-flash.s)
.equ LOGEN, var_LATEST - CELL           # 1 CELL: logging enabled flag (0 = off)
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
# CH32V006 PORT: modem receive (14-modem.s)
.equ var_MRD, var_VOCLINK - CELL        # 1 CELL: offset in MRING of the next byte mkey reads
.equ var_MTIMEOUT, var_MRD - CELL       # 1 CELL: how many ms mkey waits for a byte (see mtimeout)
# CH32V006 PORT: I/O vectors. var_OUT: the routine emit, type and the words
# built on them send a character through (a0 = the character; it may clobber
# t0 and t1 only, like uart_put). var_IN: an input table, [0] = get a
# character (a0 = it, or -1), [CELL] = is one waiting (a0 = 0 or -1). Errors
# and boot point both at the console (reset). The REPL itself always uses the
# console: its echo, ok and the error messages do not follow these.
.equ var_OUT, var_MTIMEOUT - CELL       # 1 CELL: output routine (see >console >modem)
.equ var_IN, var_OUT - CELL             # 1 CELL: input table (see <console <modem)
# CH32V006 PORT: tick interrupts taken since boot (13-ticks.s, see irqs)
.equ var_IRQS, var_IN - CELL            # 1 CELL
# A new variable goes here, and MSP_TOP below is set to it.

# CH32V006 PORT: the machine stack (register sp), under the variables. With the
# hardware prologue/epilogue (HPE) on, the QingKe V2 saves ra, t0-t2 and a0-a5
# (10 registers, 40 bytes) at sp-4 ... sp-40 when an interrupt or a trap is
# taken, and moves sp down 48 bytes (processor manual 3.4, Table 3-3; the
# manual does not say what the last 8 bytes are for). So sp is left to the
# machine: interrupt frames and the return addresses of nested subroutines.
# Forth's data stack has a register of its own (s0) and no interrupt writes
# near it. MSTACK_SIZE = one frame (48) + 12 cells for subroutines.
.equ MSTACK_SIZE, 96
.equ MSP_TOP, var_IRQS                  # address of top of machine stack
.equ MSP_BOTTOM, MSP_TOP - MSTACK_SIZE  # its lowest address

# Scratch area (see pad). The kernel only builds numbers in it, downwards
# from its middle (<# in 10-forth-words.s). CH32V006 PORT: it is one flash
# page long, and the SMS being written is meant to live here.
.equ PAD_SIZE, 256
.equ PAD, MSP_BOTTOM - PAD_SIZE
# CH32V006 PORT: pending batch buffer for the log. Lines of a multi-line
# definition are held here and committed to flash only when a line ends with
# STATE = 0, so a definition reaches the log whole or not at all. It is in
# use only between the lines of a definition typed with +log on, so a running
# word may stage a user flash page in it (planned for the call log).
.equ LOGBUF_SIZE, 256
.equ LOGBUF, PAD - LOGBUF_SIZE
# CH32V006 PORT: modem receive ring. DMA1 channel 7 writes every byte USART2
# receives into it, round and round (14-modem.s). A power of two, so an
# offset wraps with one AND.
.equ MRING_SIZE, 256
.equ MRING, LOGBUF - MRING_SIZE
# CH32V006 PORT: reserved for drivers that are not written yet; nothing uses
# these two. MLINE: one line of the modem's answer, copied out of the ring so
# that s= scan /string see it in one piece (a text-mode SMS is 160 characters
# at most). FRAME: the display's pixels, 5 rows of 2 cells (enough for 5x42).
.equ MLINE_SIZE, 160
.equ MLINE, MRING - MLINE_SIZE
.equ FRAME_SIZE, 40
.equ FRAME, MLINE - FRAME_SIZE

# CH32V006 PORT: the top of the user dictionary is the lowest buffer. Every
# dictionary bounds check and the error path's zero-fill stop at DICT_TOP, so
# a new buffer is carved out below the lowest one and DICT_TOP moves to it.
.equ DICT_TOP, FRAME

# dictionary grows upward from the RAM base address
.equ FORTH_SIZE, DICT_TOP - RAM_BASE    # remaining memory for Forth

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
