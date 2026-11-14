# sixforths

A Forth operating system for a DIY LTE phone (earlier working name: fotrh). It is a port of the FiveForths
indirect-threaded Forth (RISC-V assembly) to the WCH CH32V006F8U6 microcontroller.
The owner types Forth over UART; the phone's features are Forth words.

Hardware around the MCU: Waveshare A7670E LTE Cat-1 HAT (driven with AT commands
over UART), 8 pushbuttons, a microphone, a speaker, an LED matrix (5x32 / 5x42,
MBI5024 shift-register chain), and an SD card over SPI for call recordings.

The owner knows RISC-V assembly and Forth well, prefers the command line and vi,
and is **new to Claude Code**: explain what you are about to do in plain words,
keep steps small, and say what a command does before running anything that touches
hardware.

## The chip (these facts cause most bugs)

- QingKe V2C core: **RV32EC + Zmmul + Zicsr**. 62 KiB flash, 8 KiB SRAM, HSI 24 MHz.
- **RV32E has only x0-x15.** Never use s2-s11 or t3-t6. The assembler flags are
  `-march=rv32ec_zicsr_zmmul -mabi=ilp32e`. If a port from RV32I code used s2 / t3 /
  t4 / t5 / t6, they became s0 / a4 / a5 / gp / tp.
- **Misaligned `lw` / `sw` / `lhu` trap.** Put `.balign CELL` before any data read with
  `lw`. The `number` routine uses byte loads on purpose.
- **Zmmul has `mul` only.** No `div`, `rem`, `mulh`, `mulhu`. `um*` is built from
  16x16 `mul`s; `um/mod` is shift-and-subtract. The emulator also lacks `mulh*`.
- 1 flash wait state at 24 MHz. CFGR0 is written wholesale to 0.
- Standard halfword flash programming (PG) reportedly **corrupts neighbouring
  halfwords on real V006 silicon**. Use fast page operations instead, and note the
  **V006 fast page is 256 bytes** (the CH32V003's is 64): FTER erases a page, FTPG
  programs one through the page buffer (BUFRST, 64 x word store + BUFLOAD, FLASH_ADDR,
  STRT; reference manual 18.4.5). The emulator faults on PG, on a half-loaded buffer,
  and on programming a page that is not erased.
- Trap handler (`src/03-interrupts.s`) prints `T<mcause> <mepc>` in hex over UART and
  hangs. Traps use a vector table at 0x0 (`_start` in `sixforths.s`, `mtvec` = 3; the V2
  needs the table 1 KiB aligned): entry 0 = reset jump, 2 = NMI, 3 = every exception,
  12 = the SysTick tick (`tick_isr`). Entries 0-12 exist; enabling another interrupt needs
  the table extended to its number. **Never tell
  reset from a trap by `mcause`: on silicon it is not 0 after reset** (read 0x800000D9).
  Do not put a `.balign 1024` back; it cost ~1.6 KB of padding. If the board prints that, the code did something illegal at that address.
- Holding **PD4 high at reset keeps line 0 from loading** (see "Source lines in flash"
  below). This is the recovery switch if a bad line 0 stops the board booting. On the owner's WeAct board
  the closed solder bridges SB3/SB4 join PD4 to PD5 (UART TX). PD5 is high as the TX
  and also when released (the WCH-LinkE's RX pulls it up), so `gpio_init` samples PD4
  with PD5 driven low for only ~0.5 us (7 instructions; a ~3 us pulse showed up as a
  stray character before the banner); never read PD4 any other way. The emulator
  models this with `weact_bridge = True`.

## Forth architecture

- Registers (changed 2026-11-14): `s0` = DSP (data stack), `tp` = RSP (return stack),
  `s1` = IP, `a0` = W (NEXT hands W to the code-field routine). **`sp` is the machine
  stack**, not a Forth stack: the QingKe V2 stacks its 48-byte interrupt frame there
  (hardware prologue, processor manual 3.4), and nested subroutines keep `ra` there
  (`addi sp, sp, -CELL` / `sw ra, 0(sp)` ... `lw ra, 0(sp)` / `addi sp, sp, CELL`).
  `s0`, `tp`, `s1` are the registers no subroutine and no interrupt touches.
  Registers keep their ABI names in the source; there are no aliases.
- Scratch inside a primitive: `t0-t2`, `a1-a5`, `gp`. Prefer `a1-a5` in new code: the
  2-byte forms of `lw` / `sw` through a pointer (the data stack's `s0` included), `and` /
  `or` / `xor` / `sub` and `beqz` / `bnez` only take `s0`, `s1`, `a0-a5`, for both
  registers. **`t0` is clobbered by PUSH / PUSHRSP / POPRSP / checkunderflow** (not by
  POP). **NEXT clobbers `a5`.** `ra` is for `call` / `ret` only.
- The machine stack is 96 bytes (`MSTACK_SIZE`: one frame + 12 cells), under the
  variables and above `PAD` (nothing checks `sp` on the chip: an overrun now lands in
  scratch, not in STATE / HERE / LATEST); `boot` and `reset` empty it (`li t0, MSP_TOP` / `mv sp, t0`: `sp` gets its value
  in one instruction). A primitive must leave `sp` as it found it; a jump to an `err_*`
  label from inside a subroutine is fine, because `reset` empties the stack. Interrupts
  must not nest. PUSH and PUSHRSP move the pointer first, then store, so to push `s0`
  itself copy it to a register first (see `sp@`). The emulator faults if an interrupt
  finds `sp` outside the machine stack or without room for a frame.
- Indirect threaded. Word header: link cell, flags+length byte, name, zero padding to
  a cell boundary, then the code field. Flags: `F_IMMEDIATE` 0x80, `F_HIDDEN` 0x20,
  `F_LENMASK` 0x1f, so **names are at most 31 characters**.
- Define words with jonesforth's macros (`src/02-macros.s`): `defcode name, namelen,
  flags=0, label` for assembly (`defcode "1+",2,,ONEPLUS`), `defword name, namelen,
  flags=0, label` for a thread (`defword "2+",2,,TWOPLUS` then
  `.int ONEPLUS, ONEPLUS, EXIT`). Labels: `name_X` = header, `X` = codeword (what threads
  list), `code_X` = machine code. Headers, codewords and threads go to `.rodata`, machine
  code to `.text`; after a `defword` thread, write `.text` before any plain code. The flag
  is `F_IMMEDIATE` (jonesforth: `F_IMMED`). A wrong `namelen` stops the build with
  "namelen of X does not match its name" (the line number points into the macro).
- Console messages: `message name, "text"` defines one (`msg_name` ... `end_name`),
  `print_message name` prints it, `print_error name, jump` makes the handler `err_name`.
  No lengths are counted by hand. `token` (05) returns the next word of the TIB and moves
  `>in` past it; `:` and `create` both build their header with `make_header`.
- Words chain automatically in assembly (include) order through `link`. `last_word`,
  set after the last include in `sixforths.s`, is where LATEST starts at boot, so there is
  no chain tail to update by hand.
- Forth truth values are -1 / 0. `'` is state-smart. `branch` / `0branch` targets are
  absolute addresses. `emit` sends exactly one byte (no leading space).
- `number` parses decimal or `0x` hex (uppercase A-F). There is no BASE for input;
  `base` (a RAM cell, `var_BASE`) only affects output words.
- HERE may be unaligned after `c,` or an odd `allot`. `,`, `:`, `create` and the error path
  round it up themselves; a misaligned `sw` would trap.
- After every error `reset` calls `abandon_def`: if the newest word is still hidden (a word
  is hidden exactly while it is compiled) it is unlinked and HERE moves back. `reset` also
  puts CONTEXT and CURRENT back to FORTH.
- Vocabularies, fig-Forth style. A vocabulary is known by its head cell (the cell holding
  its newest word); FORTH's head cell is `var_LATEST`. `var_CONTEXT` = searched first (then
  FORTH), `var_CURRENT` = where definitions go, `var_VOCLINK` = list of vocabularies for
  `forget`. Words: `vocabulary` `definitions` `forth` `context` `current` `voc-link` `>body`
  `dovoc`, and `find-name-in ( addr len voc -- header | 0 )` for one vocabulary only.
  `latest` returns the head cell of CURRENT. Subroutines: `search_chain`, `search_order`,
  `lookup` in `05-internal-functions.s`.
- A variable cannot live in flash. A kernel variable is a RAM cell `var_X` in
  `01-variables-constants.s` plus a `defcode` that pushes its address (`base`, `hld`).
- CREATEd words are laid out `[header][cfa][DOES> slot][data]`.
  `dovar` / `docon` / `docol` / `xdoes` are the runtime code fields.

## Memory map (verify with `riscv64-unknown-elf-nm sixforths.elf`)

- Flash 0x00000000: kernel + `.rodata`, **must stay under 16 KiB** (`FLASH` `LENGTH` in
  `linker.ld` at the repo root; confirm it says 16k).
  Currently 13,580 bytes (184 words). Report the size after every change.
- Flash 0x08004000-0x08006800 (`LINES_BASE`..`LINES_TOP`, 10 KiB): 160 source lines of
  64 bytes (see "Source lines in flash").
- Flash 0x08006800-0x0800F800 (`USER_FLASH`..`FLASH_TOP`, 36 KiB): the application's own
  data, written a 256-byte page at a time with `fpage-erase ( page -- )` and
  `fpage-prog ( src page -- )`. Both words refuse any other address, so they cannot damage
  the kernel or the source lines. Planned use: the call log in the top 4 KiB (0x0800E800-0x0800F7FF,
  see `etc/answers.md`). The phonebook and the SMS stay on the SIM for now; they may move
  to the user flash or the SD card later, depending on how much the SIM holds (not known
  yet, see `etc/answers.md` section 9).
- RAM 0x20000000: the user dictionary grows up from here (`HERE`). It is **empty after
  boot**: every kernel word lives in flash.
  `FORTH_SIZE` = 0x1898 = **6,296 bytes** of dictionary budget, up to `DICT_TOP` (which is
  `FRAME` now).
- RAM, top down (changed 2026-11-14: the variables moved above the machine stack):
  `DSP_TOP` 0x20002000 (the data stack, 64 cells), `RSP_TOP` 0x20001F00,
  `TIB_TOP` 0x20001E00, `TIB_BOTTOM` 0x20001D00 (256 B), then the 16 variable cells:
  `var_STATE` 0x20001CFC, `var_TOIN` 0x20001CF8, `var_HERE` 0x20001CF4, `var_LATEST`
  0x20001CF0, `var_SRC` and `var_SRCEND` (the lines being loaded), `var_BASE` 0x20001CE4,
  `var_HLD`, `var_CONTEXT`, `var_CURRENT`, `var_VOCLINK` 0x20001CD4, `var_MRD`,
  `var_MTIMEOUT` 0x20001CCC, `var_OUT`, `var_IN` 0x20001CC4 (the I/O vectors), `var_IRQS`
  0x20001CC0 = `MSP_TOP` (the machine stack, 96 bytes, down to `MSP_BOTTOM` 0x20001C60),
  `PAD` 0x20001B60, `PAGEBUF` 0x20001A60 (one flash page), `MRING` 0x20001960 (the modem's
  256-byte receive ring), `MLINE` 0x200018C0 (160 B, one line of the modem's answer) and
  `FRAME` 0x20001898 (40 B, the display's pixels: 5 rows
  of 2 cells) = `DICT_TOP`. `MLINE` and `FRAME` are reserved; no code uses them yet.
  RAM-variable cells are named `var_X` as in jonesforth, so the bare names
  stay free for word labels; `TIB_BOTTOM` is the start of the input buffer.
  **A new variable** goes at the end of the variable list and `MSP_TOP` is set to it (the
  "RAM map" test fails if that is forgotten). **A new buffer** (SD sectors; left out for
  now) is carved out below the lowest one in `01-variables-constants.s`, and `DICT_TOP`
  moves down to it: every dictionary bounds check and the error path's zero-fill stop at
  `DICT_TOP`. Each buffer shrinks `FORTH_SIZE`.
- Planned sharing, so that no more buffers are needed: the SMS being written lives in
  `PAD` (256 B, one flash page; the kernel only builds numbers below `pad+128`), and a
  call-log page is staged in `PAGEBUF`, which `p` uses only while it runs.

## REPL quirks (they affect how tests and prelude files must be written)

- `(` ... `)` and `\` to end of line are swallowed **before** they reach the TIB.
  Never put them inside names or strings. A trailing `\ comment` merges the next line,
  so write comments on lines of their own.
- The TIB is 256 bytes: keep every source line under 250 characters.
- CR is ignored; ANSI escape sequences are swallowed; BS / DEL are handled. The LF that
  ends a line is echoed, so its output and `ok` start on the next line (tests expect
  e.g. `"65 emit\nA"`). A `\` comment swallows its LF without echo (the line merges).
- The interpreter does not read UART while it processes a line (the receiver holds
  only 1-2 bytes). Anything that feeds the board automatically must wait for the echo
  or prompt after each line.

## Source lines in flash

This replaced the source-replay log on 2026-11-14 (the owner found the appending log too
complex; nothing is saved automatically any more). Flash holds 160 numbered lines. Each
has a 64-byte slot: the text (up to 63 characters), a newline, then unused bytes that stay
0xFF. A slot that was never written is all 0xFF and counts as an empty line.

- `n p text` puts the rest of the input line into line n, in flash at once (`20 p : sq dup * ;`).
  It copies the line's page (4 lines) to `PAGEBUF`, rebuilds the slot, erases the page,
  programs it and reads it back (`? flash` if that differs). It prints `?` and writes
  nothing if n is not 0-159 or the text is over 63 characters. `n p` alone empties a line.
- `a b list` prints lines a to b with their numbers.
- `a b load` interprets lines a to b as if typed (they echo, each gets its `ok`). The
  lines are read once the current input line is finished, so **`load` goes last on its
  line**; a `load` in a loaded line replaces the range and does not come back. An error
  in a loaded line abandons the rest.
- `n line` gives the slot's address. `wipe` erases all 160 lines.
- **Line 0 is interpreted at boot** unless PD4 is held. It usually holds a `load`.
- Comments never reach a line (the REPL swallows them first). The master copy of the
  source is a file on the PC; `awk '{ print NR+3, "p", $0 }' file.f` numbers it from line 4.
- Inside: `uart_get` (`04-io-helpers.s`) takes its bytes from `var_SRC` up to `var_SRCEND`
  while `var_SRC` is not 0, skipping 0xFF; `reset` clears it. `fpage-erase` / `fpage-prog`
  still refuse the lines, and `p` refuses everything else.
- A power cut between erase and program loses the 4 lines of that page; the other pages
  still load.

## Build, test, flash

Run from the repo root:

    make                              # sixforths.elf / .bin / .hex / .dump
    riscv64-unknown-elf-size sixforths.elf   # kernel size; text must stay under 16384
    python3 emulators/test_fotrh.py   # boots sixforths.bin in the emulator, loads prelude.f, runs all tests
    python3 emulators/check_threads.py  # compares the threads in src/10-forth-words.s with the compiler's output

The Makefile runs `riscv64-unknown-elf-as -g -march=rv32ec_zicsr_zmmul` with
`-I src`, then `riscv64-unknown-elf-ld -m elf32lriscv -T linker.ld`, then `objcopy`. The `.o` depends on every `src/*.s`, so a new `.s` file in `src/` is picked up
automatically (add its `.include` to `sixforths.s`). Ubuntu package:
`binutils-riscv64-unknown-elf`. Build outputs are git-ignored.

Hardware (the board is plugged in through a WCH-LinkE, attached to WSL2 with usbipd-win):

    minichlink -w sixforths.bin flash -b    # program the chip and reboot
    picocom -b 115200 --imap lfcrlf --omap crlf --send-cmd "ascii-xfr -sv -l 100" /dev/ttyACM0
                                            # talk to the REPL (Ctrl-A Ctrl-X to quit)

The two maps are needed: the board ends its lines with LF only, and it ignores CR,
so Enter (CR) must be sent as LF. `make term` runs the same picocom command. To send a
Forth source file, press Ctrl-A Ctrl-S and give its name: ascii-xfr sends one line, then
waits 100 ms (the board does not read the UART while it processes a line). What it
defines lives in RAM, so a reset loses it; lines put with `p` stay in flash.

Layout:
- `sixforths.s` (repo root) is the top-level file. It includes `src/mcu.s`, then
  `src/01-*.s` ... `src/14-modem.s` **in that order**. The dictionary follows the
  include order, and `.equ last_word, link` after the last include marks its end. It is
  searched from the end, so words in later files are found first.
- `src/mcu.s` holds the chip's constants: `RAM_SIZE`, pin and register equates.
  `linker.ld` (repo root) holds the memory regions. Nothing is placed in its RAM region,
  but keep its `LENGTH` equal to `RAM_SIZE`.
- `src/08-primitives.s` holds every word written in machine code, sorted by function:
  inner interpreter, data stack, return stack, memory, arithmetic, logic, comparison,
  strings and parsing, compiler and dictionary, vocabularies, input and output, system.
  Put a new primitive into its group. The code-field routines (`docol`, `dovar_code`,
  `docon_code`, `dodoes_code`, `dovoc_code`) open the file.
- `src/10-forth-words.s` holds the colon words that live in flash, as hand-written threads
  (`defword` + `.int` lists): control flow, defining words, number output, strings, `find`,
  `vocabulary`, `.s`, `dump`. The file's header explains how to write one. **The comment above
  each thread is its Forth source and must stay true**: `emulators/check_threads.py` types
  that comment into the kernel's compiler and compares the result with the thread.
- Machine code or thread? Byte loops and stack shuffling are shorter and faster in machine
  code (`type`: 32 bytes against 64); words that mostly call other words are shorter and
  safer as threads.
- `src/12-flash.s` holds the FPEC routines, the source lines (`line` `p` `load` `wipe`;
  `list` is a thread in `10-forth-words.s`) and the user flash page words.
- `src/13-ticks.s` holds `ticks` and `ms` (SysTick, polled), the tick interrupt `tick_isr`
  and `irqs`.
- `src/14-modem.s` holds the modem UART: USART2 received by DMA into `MRING`, and the
  words `mkey?` `mkey` `memit` `mtimeout` `>modem` `<modem`.
- `emulators/` holds `rv32emu.py` (the owner's RV32EC emulator: alignment, RV32E register
  use, FPEC sequencing and illegal instructions all fault), `harness.py` (boots
  `../sixforths.bin` in it), `test_fotrh.py` (the tests; it loads `../prelude.f`) and
  `check_threads.py`. Tests must pass before a change is called done.
- `prelude.f` (repo root) is the place for Forth words that are still being developed. It
  is empty now: its 57 words moved into flash. A word tried out there (or kept in
  the flash lines with `p`) is moved into `08-primitives.s` or `10-forth-words.s` once it is stable.
- `etc/board.py` talks to the board over the UART for hardware tests (see Phase 2).
- `etc/answers.md` holds the design decisions behind the kernel layout and the plan for the
  phone (registers, flash, call log format, vocabularies, key input). Read it before
  starting on a driver.
- `docs/` holds reference PDFs (CH32V00xRM register manual, CH32V006 datasheet, pinout, the
  A7670X HAT schematic, Moving Forth parts 1-8). Read only the pages you need.
  `docs/docs-from-claude/` holds files handed over from chat; `old-docs/` looks like older
  notes. Neither is source.

## How to work here

1. After **every** change: run `make`, then `python3 emulators/test_fotrh.py`, and after a
   change to `src/10-forth-words.s` also `python3 emulators/check_threads.py`. Report the
   kernel size against the 16 KiB cap and any test that fails. If a build or test
   fails, fix the cause; do not delete or loosen a test to make it pass.
2. Add a test in `emulators/test_fotrh.py` for every new word, including edge cases (negative
   numbers, zero, overflow, divide by zero, overlapping `move`).
3. **Never flash, wipe, or erase flash without asking first.** Before anything that
   writes the source lines, read them back and tell the owner what is there. Explain in
   one sentence what the command will do to the board.
4. Hardware tests over UART: sync on the echo after every line, and wait for `ok` or `?`
   rather than for a pause (a line like `5000 ms` prints nothing for seconds, and the
   board does not read the UART meanwhile); save and restore
   `here` / `latest`; run the Forth words `s0 sp!` between tests (the Forth word `s0` = data-stack base; the
   register `s0` is the data stack pointer); start from a known state (lines wiped
   or PD4 held); treat a `T<mcause> <mepc>` line as a failed test, then reset the chip
   with minichlink.
5. Work on a feature branch (the current one is `kernel-phase1`, cut from
   `extended-wordset`). Make small commits.
   Run `git log --oneline -20` first and match the existing commit message style.
   Never push without asking.
6. Match the existing assembly style and comments. Where the source marks deliberate
   differences from upstream FiveForths (look for `CH32V006 PORT:` comments), keep
   marking them the same way.
7. Prefer changing a small number of files at a time. If a task needs more than a few
   files, say so and propose the plan first.

## Open work

Done in `kernel-phase1` (all tested in the emulator; flashed on 2026-11-12, and the Phase 2
step 1 checks passed on the board): HERE alignment, interrupt-safe PUSH, the merged
primitives file, the prelude in flash, `s=` `scan` `/string`, the user flash page words,
error recovery by the hidden flag, vocabularies. `fpage-erase` ran on the board in the step 3
experiment; `fpage-prog` has not run there yet.

Still open from before:
- The source lines: holding PD4 at reset (line 0 must not load) is not checked on the
  board yet; it needs a hand on the button.
- A pyserial backend for `emulators/test_fotrh.py`, so the same tests run against the real
  board (and against the emulator through a fake port).
- Optional: `?do`.

## Phase 2: the phone hardware

**Where we stopped (2026-11-12): waiting for the display and key hardware**, which may
take more than a month.
- The board runs commit `2970f96` (13,728 bytes; flashed 2026-11-14: the machine stack on
  `sp`, `s0` = DSP, `tp` = RSP). Checked there besides the list that follows: `/mod` `/`
  `mod`, 64 cells fit and the 65th overflows, `0 rp! nosuchword` prints `?`, a wrong
  `sp!` / `rp!` prints `?`, `memit` / `mkey` and `>modem` through the D2-D3 wire, a
  vocabulary, and a `+log` round trip (a one-line and a two-line definition replayed after
  `reboot` and after a hardware reset, then `wipe`; the read-back showed the kernel equal
  to `sixforths.bin` and the log empty). **Since 2026-11-14 the board runs `9f1401a`**
  (13,580 bytes: the source lines instead of the log). Checked there: `p` `list` `load`
  with two lines, ten `p` in a row (5 of 398 ticks lost in 796 ms), one line changed with
  its page neighbours intact, `160 p` prints `?`, line 0 after `reboot` and after a
  hardware reset, a bad line 0 (`?`, then the prompt), one `p` takes about 5 ms from the
  echo to `ok`, `wipe`. The read-back showed the kernel equal to `sixforths.bin`, the
  lines and the user flash empty, and the old kernel's last 148 bytes still after the
  new one (0x350C-0x359F), as expected.
  Checked: boot, an error with 3 cells on the stack and one inside
  a definition (both leave `depth` 0), 40 cells through 1000 ms of ticks (500 ticks, the
  sum intact), `reboot`. Flashing printed one stray byte before the banner; a plain
  `minichlink -b` reset did not. Its source lines are empty
  and the user flash is empty. A wire joins D2 and D3 (the USART2
  loopback; D2 is driven as an output at every boot) and the board's USB-C socket is
  unplugged. Nothing else is connected.
- Next: 5b (the LED rows in the tick) once the matrix is wired, then 5c (the keys). Ask
  the owner how it is wired before writing code, and check it against the pin table.
- Before trusting any of this after the pause: `make`, run the tests, and read the
  board's flash back (`minichlink -r <file> 0x08000000 0xF800`, read only) to see what
  it really holds. WSL may need the WCH-LinkE attached again (`usbipd attach --wsl
  --busid <id>` on Windows; `usbipd list` shows the id).
- `etc/board.py` sends Forth lines to the board and waits for each echo and `ok` (its
  docstring has the commands); `etc/flash-before-fable.bin` is the board's flash from
  before this kernel.

Work this list from the top, **one item per session**, and stop after each for the owner
to test on the board. The reasons behind each choice are in `etc/answers.md`.

Rules for all of it:
- The emulator models SysTick (one HCLK cycle per instruction), USART2 and DMA channel 7
  (a test puts the modem's bytes in `uart2_in`; `uart2_loopback` is a PD2-PD3 wire), and
  faults on the parts of them it does not model. Interrupts: SysTick's compare interrupt
  (12) only, with the HPE frame and `mret` (nesting, HPE off and other `mtvec` modes
  fault); a test can hold it off by clearing MIE in `e.csr[0x300]`. It has no TIMx.
  Before writing a driver, add
  the smallest model of that device to `emulators/rv32emu.py` so the words can be tested
  there, and say plainly which part can only be checked on the board.
- Look every register address and bit up in `docs/ch32v006/CH32V00XRM.PDF` (only the pages
  needed) and quote the section in a comment. Do not write a register from memory.
- A device gets its own numbered file with its machine code and its words (`14-modem.s`,
  `15-display.s`, ...); pin and register equates go to `mcu.s`. Keep one pin table in this
  file once pins are assigned (the QFN20 has few: count them before promising one).
- Interrupts: at most **one**, and it must not nest. Its routine may use `ra`,
  `t0-t2`, `a0-a5` freely (the hardware prologue saves exactly those); to use `s0`, `s1`,
  `gp` or `tp` it must save them on the machine stack (`sp`) and restore them, within the
  12 cells `MSTACK_SIZE` leaves. The one interrupt is the tick (step 5a), vector table entry 12;
  another would need the table extended to its number. HPE and the vector mode are set in CSRs described in
  `docs/ch32v006/QingKeV2_Processor_Manual.PDF` chapter 3.
- Everything that waits (for the modem, for a key) needs a timeout. A phone must not hang.

Pins in use (QFN20 pin numbers from the datasheet's V006F8U7 column; the board's header
labels them D1 ... D6; its schematic is `docs/ch32v006/CH32V00xFxUx_Pinout.pdf`):

| Pin | QFN | Use |
|---|---|---|
| PD1 | 15 | SWIO, the debug pin minichlink uses |
| PD2 | 16 | USART2 TX, to the modem's RX |
| PD3 | 17 | USART2 RX, from the modem's TX (pull-up). WeAct solder bridge SB2 joins it to the USB-C D+ line (33 Ω): keep the board's USB-C socket unplugged |
| PD4 | 18 | skip button (high at reset: line 0 is not loaded); joined to PD5 by SB3/SB4 on the WeAct board |
| PD5 | 19 | USART1 TX, the console |
| PD6 | 20 | USART1 RX, the console |

The steps:
1. **First flash of this kernel.** Ask first (rule 3 above). The log on the board still
   holds the old prelude: it would be compiled into RAM on top of the same words in
   flash, so read the log back, show it, and `wipe` it with the owner's consent. Then run
   by hand: `words`, `5 6 + .`, `: sq dup * ; 7 sq .`, `3 allot nosuchword` (must print
   `?`, not a `T...` trap line), `vocabulary edit edit definitions : k3 70 emit ;
   forth definitions edit k3 forth`, and a `+log` / reset / replay round trip.
   **Done 2026-11-12**: all passed, the replay after `reboot` and after `minichlink -b`
   matched the emulator byte for byte, and the board's log is wiped again. Learned:
   `minichlink -w` rewrites only the pages it writes, so **the lines region survives a kernel
   reflash** and line 0 loads on the new kernel's first boot (send `wipe` as the first line, or
   hold PD4, when the old contents do not suit the new kernel). It also keeps the old bytes
   after the end of the image in the last page it writes: after `3b085aa` (4 bytes shorter
   than `a042149`) the old kernel's last 4 bytes stayed at 0x3518 (read back 2026-11-14).
   Do not assume the flash after the kernel is erased. minichlink sometimes prints
   `link error, nothing connected to linker` five times when it connects (3 of 7
   connections, with and without a `wipe` before), then recovers and works; cause unknown.
2. **`ticks` and `ms`.** A free-running counter read by polling (SysTick), no interrupt.
   Needed for every timeout below.
   **Done 2026-11-12, checked on the board.** `ticks ( -- u )` is the SysTick count on
   HCLK/8: 3000 per ms (`STK_TICKS_PER_MS`), wrapping every 23.9 min; `ticks t0 -` is the
   time since t0. `ms ( n -- )` treats n as signed (n <= 0 returns at once). On the board,
   `5000 ms` took 4.97-4.99 s by the PC's clock (the HSI runs 0.2-0.6% fast), writing
   STK_CNTL works, and after `reboot` the count starts again from 0.
3. **Modem on USART2, received through DMA into a ring buffer in RAM.** No interrupt: the
   main loop polls the buffer (`mkey?` `mkey` `memit`). First experiment on the board,
   before any more code: does the DMA keep storing bytes while a flash page is erased
   (the core stands still for about 3 ms)? If it does not, the call log must not be
   written while the modem may talk. Consider a lower modem baud rate (`AT+IPR`).
   **Experiment done 2026-11-12: it does.** USART1 RX through DMA channel 5 (the same
   controller as USART2's channel 7) received 2,048 streamed bytes while 16 pages were
   erased: 543 of them during the 46.8 ms of erasing (2.92 ms a page), no overrun, none
   wrong. SysTick kept counting through the stall. Page programming (FTPG) was not tried.
   USART2 can only be TX = PD2, RX = PD3 on the QFN20 (`AFIO_PCFR1` USART2_RM = 011; the
   other remaps need pins it lacks, or SWIO); its clock is `RCC_PB2PCENR` bit 13, its RX
   is DMA channel 7 (RM Table 8-2).
   **Driver done 2026-11-12, checked on the board with a wire from D2 to D3:** `mkey? ( -- flag )`,
   `mkey ( -- c | -1 )` (waits at most `mtimeout` ms, 1000 at boot; -1 if nothing came),
   `memit ( c -- )`, `mtimeout ( -- addr )`. A 256-byte ring; a reader that falls a whole
   ring behind loses bytes without an error. On the board `65 memit mkey .` printed 65, a
   1000 ms `mkey` timeout took 3,000,926 ticks, 300 bytes went round the ring with no error,
   an unread 300-byte burst left the last 44 (as in the emulator), unread bytes survived an
   error, and neither `reboot` nor a hardware reset left a junk byte. Not yet: the A7670E
   itself (read the HAT schematic in `docs/A7670X` for its UART voltage first). Found on the way: the interpreter compiled into a
   definition with no bounds check, and `;` unhid before its check (fixed, `b13ad53`).
4. **Vectored `emit` and `key`.** **Done 2026-11-12, checked on the board** (D2-D3 wire).
   `var_OUT` holds the routine `emit` `space` `cr` `type` `words` (and so `.` `u.` `."` `.s`
   `dump`) send through; `var_IN` points at an input table (get, ready) that `key` and `key?`
   use. `>console` `>modem` and `<console` `<modem` set them (step 6 adds the keypad,
   the display step `>display`); the modem's `key` gives -1 after `mtimeout` ms. The REPL's
   echo, `ok`, error messages, the banner and the trap line always use the console, and
   `reset` (boot and every error) sets both vectors back to the console. `mkey?` `mkey`
   `memit` stay as words of their own: the phone's main loop polls the console, the modem
   and the keys side by side. The owner moved the error part of this step to step 7.
   On the board: `>modem 65 emit >console mkey .` printed 65, `."` and `.` went out
   through the vector, `<modem` `key` read the wire and timed out with -1 after 10 ms,
   `>modem` stayed set across lines with the echo and `ok` on the console, and an error
   put both vectors back on the console.
5. **Tick interrupt** (about every 2 ms): refresh one LED row
   (`docs/output/LED-matrix/Bitbang-LED-matrix.S` already keeps to the allowed registers),
   sample the 8 keys through the 74HC165, count time. This is the one interrupt. Split in
   three (the owner, 2026-11-12; nothing is wired yet):
   - 5a, the tick itself. **Done 2026-11-12, checked on the board.**
     SysTick's compare interrupt every `TICK_PERIOD` (6000 ticks = 2 ms); the counter runs
     free, so `ticks` `ms` `mkey` are unchanged. `tick_isr` puts the next compare one period
     on, or one period after now when it ran late (flash work holds the core up; a compare
     in the past would not match again for 23.9 minutes), and counts `irqs`. HPE is on, so
     traps stack a frame too. On the board: 500 ticks in 1000 ms, 2500 in 5.0012 s; 16 page
     erases (46.9 ms) let 16 late ticks through and the tick was back at 500 a second at
     once; a 40-cell stack survived the ticks; `reboot` and a hardware reset restart it.
   - 5b, the LED row refresh in the tick (pins PC0, PC2, PA1, PA2; needs the matrix wired).
   - 5c, the keys through the 74HC165 (shares CLK and OE, one more input pin; not tried).
6. **Key input**: chords are decoded on release (OR everything pressed since the first
   press, report it when all keys are up). Characters are entered with two strokes through
   a 64-byte table, `map[8 * first + second]`.
7. **Modes**: one vocabulary per mode (idle, dial, call, edit, ...), a variable that holds
   the current mode's vocabulary, and a handler that builds a name from the key mask
   (`k13` for keys 1 and 3) and looks it up with `find-name-in`, then in a common
   vocabulary. Do not switch CONTEXT from the key handler.
   **Errors must work without a console** (moved here from step 4). On the finished phone
   nothing is connected to USART1, so an error must not fall back to the console REPL (the
   owner, 2026-11-12). `reset` restarts the word held in a RAM cell instead: the REPL by
   default (developing, with a PC attached), or the phone's main loop, which puts itself
   there when it starts (from line 0, or from the lines it loads). That word sets the vectors it
   needs and shows the error, kept in RAM by the error path: the REPL on the console as
   now, the phone on the LED matrix (for example `?` and the word's name), cleared with a
   key. A trap still sends `T<mcause> <mepc>` to the console; on the phone it then resets
   the chip (later through the watchdog) instead of hanging. A restart word that fails at
   once would restart forever: a hardware reset clears the RAM cell, and PD4 skips the line 0
   that sets it again. A REPL on the matrix and the 8 keys is possible later, but slow.
8. **Call log** in the user flash, 16-byte records (format in `etc/answers.md`).
