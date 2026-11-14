# Source lines in flash: the permanent storage of sixforths

Written 2026-11-14, for the kernel at commit `9f1401a` (13,580 bytes). This text explains
what the storage is, how to use it, what happens in flash and in RAM for every operation,
why it is built this way, and how it compares with the blocks of classical Forth and with
the source-replay log it replaced.

The code is in `src/12-flash.s` (the words `line` `p` `load` `wipe`), `src/10-forth-words.s`
(`list`), `src/04-io-helpers.s` (`uart_get`, the reader) and `src/06-initialization.s`
(boot and `reset`).

## 1. What it is, in one paragraph

Flash holds **160 numbered lines of Forth source**, line 0 to line 159. You put text into a
line with `p`, look at lines with `list`, and have them interpreted with `load`. A line you
put is in flash when `ok` appears; there is nothing to save afterwards. At power-on the
board interprets **line 0**, and line 0 normally says which other lines to load. That is
the whole model. The words a line defines are compiled into RAM, exactly as if you had
typed the line, so what is permanent is the *source*, not the compiled code.

## 2. Using it

### The words

| Word | Stack | What it does |
|---|---|---|
| `p` | `( n -- )` | Puts the rest of the input line into line n, in flash, at once. |
| `list` | `( a b -- )` | Prints lines a to b, each with its number. |
| `load` | `( a b -- )` | Interprets lines a to b as if you typed them. |
| `line` | `( n -- addr )` | The address of line n's slot in flash. |
| `wipe` | `( -- )` | Erases all 160 lines. |

### A session

    20 p : sq dup * ;
       ok
    21 p : cube dup sq * ;
       ok
    20 21 list
    20 : sq dup * ;
    21 : cube dup sq * ;
       ok
    20 21 load
       ok
    : sq dup * ;
       ok
    : cube dup sq * ;
       ok
    3 cube .
    27    ok

To correct a word, put its line again. The old text is replaced:

    21 p : cube dup dup * * ;

To empty a line, give `p` no text:

    21 p

### The boot line

Line 0 is interpreted at every boot, after the banner. To have lines 20 and 21 loaded at
every power-on:

    0 p 20 21 load

After a reset the console then shows what was loaded, as if it had been typed:

    sixforths v0.0

    20 21 load
       ok
    : sq dup * ;
       ok
    : cube dup dup * * ;
       ok

Line 0 may hold any Forth text of up to 63 characters. On the finished phone it will end
by starting the phone's main word.

### Rules to remember

- **`load` goes last on its line.** The lines are read when the current input line is
  finished, so `20 21 load 3 cube .` runs `3 cube .` *first* (and fails, because `cube` is
  not defined yet).
- **`load` does not come back.** A `load` inside a loaded line replaces the range that was
  being loaded. When the new range ends, input returns to the console, not to the line
  that said `load`. So a `load` goes on the last line of a range as well.
- **An error abandons the rest.** If a loaded line prints `?`, the lines after it are not
  loaded and you are back at the console. The failing line is the last one echoed.
- **A line is at most 63 characters.** A longer text gives `?` and nothing is written. A
  definition may run over as many lines as it needs.
- **Exactly one space after `p` is skipped.** Further spaces are kept, so a continuation
  line can be indented.
- **Comments are not stored.** The REPL removes `( ... )` and `\` comments before a word
  ever sees the line (this is an old property of the kernel, see `CLAUDE.md`, "REPL
  quirks"). The commented master copy of the source is a file on the PC.
- **Do not call `key` or `key?` from a loaded line.** While lines are loaded, `key` takes
  its characters from the lines, not from the console.
- **Nothing is saved by just typing.** Only `p` writes.

### Recovery

If line 0 does something that stops the board from reaching the prompt (for example it
starts a main loop that hangs), hold **PD4 high while resetting**. Line 0 is then not
loaded and the board comes up with a bare prompt, where `0 p` or `wipe` repairs it. A line
0 that merely has an error needs no recovery: it prints `?` and the prompt works.

### Sending a file from the PC

Keep the source in a file and let `awk` number it. Comment lines and empty lines must be
taken out first:

    grep -v -e '^\\' -e '^ *$' phone.f | awk '{ print NR+3, "p", $0 }' > phone.lines

This numbers the lines from 4 upwards (`NR+3`). Send `phone.lines` with picocom (Ctrl-A
Ctrl-S). Two things to check before sending:

- No line over 63 characters: `awk 'length($0) > 63' phone.f` must print nothing.
- No line that *starts* with a backslash is sent with a number in front. `7 p \ a comment`
  would swallow the newline, and line 7 would receive the *next* line of the file, number
  and `p` included. That is why the `grep` above removes those lines. Comments in
  parentheses inside a line are harmless: they are simply left out.

How much fits: your old prelude was 58 lines (5 of them over 63 characters, so about 63
lines here) and compiled to about 2.8 KiB of RAM. The dictionary is 6,296 bytes, so
roughly 130 such lines fill the RAM. 160 lines is therefore about as much source as the
board can compile at one time.

## 3. In flash

### Where

| Flash | Size | Use |
|---|---|---|
| 0x08000000-0x08003FFF | 16 KiB | kernel |
| 0x08004000-0x080067FF | 10 KiB | **the 160 lines** (`LINES_BASE` .. `LINES_TOP`) |
| 0x08006800-0x0800F7FF | 36 KiB | user flash (call log and other data) |

Line n is at `0x08004000 + 64 * n`. Line 0 is at 0x08004000, line 20 at 0x08004500, line
159 at 0x080067C0. `n line` gives this address.

### The slot

Every line has a **slot of 64 bytes**:

    text (0 to 63 characters) | newline (0x0A) | unused bytes, all 0xFF

The 64 bytes of line 20 after `20 p : sq dup * ;` (`20 line 64 dump` prints them, in its
own layout):

    0x08004500:  3A 20 73 71 20 64 75 70  20 2A 20 3B 0A FF FF FF   : sq dup * ;.
    0x08004510:  FF FF FF FF FF FF FF FF  FF FF FF FF FF FF FF FF
    0x08004520:  FF FF FF FF FF FF FF FF  FF FF FF FF FF FF FF FF
    0x08004530:  FF FF FF FF FF FF FF FF  FF FF FF FF FF FF FF FF

Three kinds of slot exist:

- **Written, with text**: text, newline, 0xFF.
- **Written, empty** (after `n p` with no text): a newline, then 0xFF.
- **Never written** (after `wipe`, or on a fresh chip): all 0xFF, no newline.

One rule covers all three when lines are loaded: **a 0xFF byte is nothing**. The reader
skips it. So a never-written slot contributes no characters at all, and the unused rest of
a written slot costs nothing either.

### The page

The CH32V006 cannot change single bytes of flash. It erases and programs **whole pages of
256 bytes**. A page holds 4 slots: page 0 holds lines 0-3, page 5 holds lines 20-23, and
so on; there are 40 pages. This is the one place where the hardware shows through: to
change one line, the kernel must rewrite the page of four. You never have to think about
it, except for one consequence (section 6, power cut).

## 4. In RAM

The storage needs very little RAM, and none of it holds anything between two commands.

| RAM | Size | Use |
|---|---|---|
| `var_SRC` (0x20001CEC) | 1 cell | Address of the next character to load. 0 = input comes from the console. |
| `var_SRCEND` (0x20001CE8) | 1 cell | Address where the loaded range ends. |
| `PAGEBUF` (0x20001A60) | 256 bytes | One flash page. `p` builds the new page here. |
| the TIB (0x20001D00) | 256 bytes | The input line, as for typed input. |

- `var_SRC` and `var_SRCEND` are in use only while lines are being loaded.
- `PAGEBUF` is in use only while one `p` runs (a few milliseconds). When `p` returns, the
  buffer is free. That is why the planned call log may stage its page in the same buffer:
  the two can never need it at the same time.
- Nothing in RAM is a copy of flash that could differ from flash. This is the main design
  decision; section 7 explains it.

## 5. What each operation does, step by step

### `n p text`

1. Take n from the stack. If it is not 0-159, print `?` and stop.
2. Find the text in the input line: skip one space after `p`, then everything up to the end
   of the line. Move `>in` to the end, so the interpreter does not try to run the text.
3. If the text is longer than 63 characters, print `?` and stop. Nothing has been written.
4. Copy the 256-byte page that contains the slot from flash to `PAGEBUF`.
5. In that copy, fill the slot's 64 bytes with 0xFF, then store the text and a newline.
   The other three slots of the page are untouched.
6. Erase the page in flash (it then reads all 0xFF).
7. Program the page from `PAGEBUF`.
8. Read the page back and compare it with `PAGEBUF`. If they differ, print `? flash`.
9. Print `ok`. The line is in flash.

Steps 6 and 7 stop the processor (section 6). The whole `p` took about 5 ms on the board.

### `a b load`

`load` itself does almost nothing:

1. Check that a and b are 0-159 and that b is not smaller than a (else `?`).
2. Store the address of line a in `var_SRC` and the address after line b in `var_SRCEND`.

The work is done by the **reader**, the routine `uart_get` that fetches the next input
character for the interpreter. It has a switch:

- `var_SRC` = 0: wait for a character from the console (the normal case).
- `var_SRC` not 0: take the byte it points at, move the pointer on. If the byte is 0xFF,
  skip it and take the next. When the pointer reaches `var_SRCEND`, set `var_SRC` to 0 and
  go back to the console.

The interpreter does not know the difference. A loaded line passes through exactly the
same code as a typed one: it is echoed, collected in the TIB up to its newline,
interpreted, and answered with `ok`. This is why a loaded line behaves in every detail
like a typed line, and why nothing new had to be tested in the interpreter.

It also explains the two rules about `load`. The reader is only asked for a character when
the interpreter has finished the current line, so the rest of the line that contains
`load` runs first. And there is only one pointer, so a second `load` overwrites the first:
no way back.

### Boot

After the hardware is set up, boot looks at PD4. If it is low (the normal case), boot does
what `0 0 load` would do: `var_SRC` = line 0, `var_SRCEND` = line 1. Then the interpreter
starts, and its first input line comes from line 0. If line 0 was never written, the
reader skips 64 bytes of 0xFF, reaches the end, and waits for the console: nothing is
printed, not even an `ok`.

### An error

Every error ends in `reset`, which sets `var_SRC` to 0. So an error in a loaded line
returns the input to the console, and the remaining lines are not loaded. (Boot enters
`reset` just below that instruction, otherwise it would cancel its own line 0.)

### `a b list`

A colon word. For each line from a to b it prints the number, then looks for the newline
in the slot with `scan`. If there is one, it types the characters before it. If there is
none (a never-written slot), it types nothing. Then a new line. `list` reads flash directly
and uses no buffer.

### `wipe`

Erases the 40 pages, one after the other (about 3 ms each, so a bit over 0.1 s). Nothing
else is touched.

## 6. Flash physics, and what they cost

- **Erase before program.** Programming can only turn 1 bits into 0 bits. To store new
  text in a slot, its page must first be erased to all 1s (0xFF). `p` always erases.
- **The processor stops.** While a page is erased (2.9 ms, measured) or programmed, the
  core stands still, because the kernel itself runs from the same flash. Consequences:
  - The tick interrupt (every 2 ms) comes late, and a tick is skipped a bit under half
    the time. Measured: 5 of 398 ticks lost during ten `p`. `ticks` and `ms` are not
    affected, because they read the hardware counter.
  - The modem's receiver stores its bytes by DMA, which kept working during an erase
    (measured in phase 2 step 3). During programming this has not been measured.
- **Wear.** A page endures at least 100,000 erase cycles (datasheet). Every `p` is one
  cycle for one page. Sending a whole file rewrites each page 4 times (once per line).
  That allows 25,000 full uploads.
- **Power cut.** If power fails after the erase and before the programming is finished,
  the 4 lines of that page are lost (they read 0xFF, or are damaged). All other pages are
  intact and still load, because an erased page is simply skipped. The window is a few
  milliseconds per `p`, and `p` is used with a PC attached, where the source can be sent
  again.
- **A kernel reflash keeps the lines.** `minichlink -w` writes only the kernel's pages. The
  lines stay and line 0 loads on the new kernel's first boot. If the old lines do not suit
  the new kernel, hold PD4 or send `wipe` as the first line.

## 7. Why it is built this way

The aim was the simplest storage that can be understood completely, at the price of some
flash if necessary. Each choice below follows from that.

**Fixed slots of 64 bytes.** Line n is at `base + 64 * n`: one multiplication, no table,
no search, no links. Replacing a line never moves another line. The price is wasted
space: the average source line is under 40 characters, so about 40% of the 10 KiB holds
0xFF. Flash is not scarce here (the 36 KiB of user flash are still empty); RAM and
simplicity are.

**64, not another size.** Four slots fill a 256-byte page exactly, so a line never lies
across two pages and `p` always rewrites exactly one page. 64 is also the classical Forth
line length, and it fits a terminal with the line number in front.

**The newline is stored, so 63 characters.** With the newline in the slot, the reader is a
plain stream of bytes and needs no knowledge of line boundaries. The alternative (64
characters, newline invented by the reader after every 64th byte) would need extra state
in the reader. One character per line is a small price for a reader of 50 bytes.

**Unused bytes are 0xFF and 0xFF is nothing.** 0xFF is what erased flash reads anyway. So
"never written", "erased by a power cut" and "the rest of a short line" are all the same
case, and one instruction in the reader handles them. Padding with spaces instead would
have sent the spaces through the interpreter and echoed them at every load.

**`p` writes at once; there is no edit buffer and no `save`.** This is the most important
choice. If lines were first changed in a RAM buffer and written later, RAM and flash could
differ, and then every word needs a rule: does `load` read the buffer or the flash? What
happens to unsaved changes when another page is edited, when an error occurs, when the
call log needs the buffer? With `p` writing at once, these questions do not exist. Flash
is always what you last typed. The price is one page erase per line instead of one per
four lines, which costs wear and milliseconds that do not matter here.

**One flat list of lines, no block numbers.** A block of 4 lines would be too small to be
a useful unit (a longer definition would cross blocks), and a block of 16 lines would
need a 1 KiB buffer under the classical scheme. With a flat list, the unit is whatever
range you give to `list` and `load`.

**Reading needs no buffer.** Flash is part of the address space, so `list` and `load` read
the lines where they are. This is the difference from a disk (section 8) and the reason
the whole thing fits in two cells and one borrowed page of RAM.

**Line 0 is the boot line.** One fixed, simple rule. Loading all 160 lines at boot would
be even simpler to state, but then nothing could be kept in flash without being compiled
at every boot (test words, alternatives, tools), and the RAM would limit the store.

**Its own region, with a wall.** The lines keep the region of the old log. The data words
`fpage-erase` and `fpage-prog` refuse that region, and `p` refuses everything outside it.
A bug in call-log code cannot erase source, and a mistyped line number cannot erase call
history, for which there is no copy on a PC.

**`p` always erases.** It could skip the erase when the page is already blank, saving one
erase in four after a `wipe`. That is 20 bytes of code and one more case to test for a
saving nobody will notice.

**No nesting of `load`.** Returning to the calling line would need a stack of sources. One
pointer and the rule "`load` goes last" do the same job for a boot line that chains to the
application.

**Comments are not stored.** The owner decided this (2026-11-14). It keeps the REPL as it
is and saves flash; the PC file is the readable copy.

## 8. Compared with classical Forth blocks

### How blocks work

Classical Forth (fig-Forth, Forth-79, Forth-83, polyFORTH) keeps everything on disk in
**blocks of 1024 bytes**, numbered from 0. A block holding source is a *screen*: 16 lines
of 64 characters, with no line ends; every line is padded with spaces.

A disk block is not in memory, so the system keeps a few **block buffers** in RAM:

- `n block` gives the address of a buffer that holds block n, reading it from disk first
  if necessary (and writing another buffer out to make room, if that one was changed).
- `update` marks the current buffer as changed.
- `flush` (or `save-buffers`) writes all marked buffers back to disk.
- `n list` shows a screen; `n load` interprets one; `-->` at the end of a screen continues
  with the next; `a b thru` loads a range.
- An editor changes the buffer: fig-Forth's line editor has `n p text` (put line n),
  `d` (delete a line), and so on. The change reaches the disk at the next `flush`.

The interpreter reads straight from the buffer: `blk` says which block, `>in` how far.
There is no line structure at all while loading; a `\` comment skips to the next multiple
of 64.

### The same ideas, and what changed

| | Classical blocks | sixforths lines |
|---|---|---|
| Unit of storage | block, 1024 bytes | line slot, 64 bytes |
| Unit of the medium | disk sector | flash page, 256 bytes (4 lines) |
| Source format | 16 x 64, padded with spaces, no line ends | text, newline, 0xFF |
| Line length | 64 | 63 |
| Naming a line | block number and line 0-15 | one number 0-159 |
| To read | copy the block into a RAM buffer | read flash in place |
| To change | change the buffer, `update`, later `flush` | `p` rewrites the page at once |
| RAM needed | 1 KiB or more of buffers, held permanently | 256 bytes, for the duration of `p` |
| State that can be lost | changed buffers not yet flushed | none |
| Load a range | `load`, `-->`, `thru` | `a b load` |
| Nested `load` | yes (`blk` and `>in` are saved) | no; `load` chains |
| Start-up | by convention a load block | line 0 |
| Data in the same store | yes: any block may hold data | no: data has its own region and words |
| Comments in the source | yes | no (removed by the REPL) |

What is the same: source lives in numbered, fixed-size places; you put a line with `p` and
its number; `list` shows, `load` interprets; replacing a line moves nothing else; and
there is no file system, no names, no directory. In that sense the 160 lines are **one
large block of 160 x 64**, cut to the size this chip can hold.

What is different, and why:

- **No buffers.** The buffer machinery (`block`, `buffer`, `update`, `flush`) exists
  because a disk is not memory. Flash is memory for reading. Only writing needs a copy,
  and only for the moment of the write. Leaving the machinery out removes the classic
  mistakes too: a forgotten `update` or `flush`, and edits lost at a crash.
- **Smaller pieces.** 1 KiB is an eighth of this chip's RAM. A flash page is 256 bytes, so
  the natural piece that can be rewritten is 4 lines.
- **Lines with ends.** The kernel's interpreter is line-oriented (it collects a line in the
  TIB, then interprets it), inherited from FiveForths. Storing the newline lets loaded
  text go through that unchanged path. A classical interpreter parses the block buffer
  directly and needs no line ends.
- **Source only.** Classical Forth uses blocks for data as well (`block` gives an address;
  you store what you like). Here the data side is the separate pair `fpage-erase` /
  `fpage-prog` on the user flash, 256 bytes at a time, behind the wall described above.

What you lose against blocks:

- The words `block` `update` `flush` do not exist, so block-based code from books does not
  run as it is.
- No screens with a comment in line 0, no `index`, no shadow screens: the documentation
  lives in the PC file.
- No nested `load`.
- If an SD card ever holds source or data, it is a true block device (512-byte sectors,
  not in the address space), and it *will* need the classical buffers. The lines in flash
  do not help there, and do not stand in the way.

## 9. Compared with the source-replay log it replaced

Until 2026-11-14 the same flash region held a log. With `+log` on, every input line that
ended in `ok` was appended to it, and the whole log was interpreted at boot.

| | Source-replay log | Lines |
|---|---|---|
| Saving | automatic, every successful line | only `p` |
| Change one definition | `wipe` and send everything again (or both versions compile at every boot) | put its line again |
| What is in flash | everything typed while logging was on, in order, including experiments | exactly what you put, where you put it |
| Density | dense, no padding | about 40% of the region unused |
| Limit per definition | 255 bytes of source (the batch buffer) | none; 63 characters per line |
| Written to flash | appended at a moving frontier, across page borders | one whole page, at a fixed place |
| Found at boot | the frontier, by scanning for the first erased halfword | nothing to find |
| Power cut | the replay stopped at the damaged page; all later lines unreachable | 4 lines lost, the rest loads |
| At boot | everything | line 0, which chooses |

The reading half was kept almost unchanged: the switch in `uart_get`, the PD4 skip, and
"an error abandons the rest" all come from the log. The writing half went: `log_commit`
(460 bytes: batching a definition until `;`, padding to even length, merging into a
half-full page), `log_scan`, `+log`, `-log`, the hook in every `ok`, and three variables.

In bytes the change is small: the kernel went from 13,728 to 13,580 bytes, 148 less, and
20 of those were a routine nobody called. `p` alone is 252 bytes. The gain is not size. It
is that there are fewer rules to keep in mind, no state that depends on history, and that
a line can be changed.

## 10. Numbers

| | |
|---|---|
| Lines | 160, numbered 0-159 |
| Characters per line | 63 |
| Flash used | 10,240 bytes (40 pages), 0x08004000-0x080067FF |
| RAM used | 2 cells, plus `PAGEBUF` (256 bytes) during `p` |
| Kernel code | reader switch 50 bytes, `p` 252, `load` 64, `line` 48, `list` 152, `wipe` 36, plus headers and the `? flash` message |
| One `p` | about 5 ms (board, PC clock from echo to `ok`) |
| One page erase | 2.9 ms (board) |
| Endurance | 100,000 erases per page (datasheet) |

## 11. What was checked, and where

In the emulator (`emulators/test_fotrh.py`, the tests named "lines:", "p:", "list:"): the
bytes of a slot, a shorter text over a longer one, the neighbours in a page, the limits of
`p` `list` `load` `line`, a definition over several lines, erased lines and an erased page
in a range, a full 63-character line followed by another, a `load` inside a loaded line,
an error in a loaded line, line 0 at boot (written, empty, bad), PD4, the WeAct solder
bridges, `reboot`, all 160 lines loaded, `wipe`, a flash byte that does not take
(`? flash`), and that `fpage-erase` still refuses the region.

On the board (2026-11-14): put, list and load of two lines; ten `p` in a row; a changed
line with its neighbours intact; `160 p`; line 0 after `reboot` and after a hardware
reset; a bad line 0; the time of one `p`; `wipe`; and a read-back of the whole flash.

Not checked on the board yet: holding PD4 at reset with a line 0 present, and whether the
modem's DMA keeps receiving while a page is *programmed* (it does while one is erased).
