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
  needs the table 1 KiB aligned): entry 0 = reset jump, 2 = NMI, 3 = every exception.
  Only these entries exist; enabling an interrupt needs a longer table. **Never tell
  reset from a trap by `mcause`: on silicon it is not 0 after reset** (read 0x800000D9).
  Do not put a `.balign 1024` back; it cost ~1.6 KB of padding. If the board prints that, the code did something illegal at that address.
- Holding **PD4 high at reset skips the source-replay log** (see below). This is the
  recovery switch if a bad log line stops the board booting. On the owner's WeAct board
  the closed solder bridges SB3/SB4 join PD4 to PD5 (UART TX). PD5 is high as the TX
  and also when released (the WCH-LinkE's RX pulls it up), so `gpio_init` samples PD4
  with PD5 driven low for only ~0.5 us (7 instructions; a ~3 us pulse showed up as a
  stray character before the banner); never read PD4 any other way. The emulator
  models this with `weact_bridge = True`.

## Forth architecture

- Registers: `sp` = DSP (data stack), `s0` = RSP (return stack), `s1` = IP, `a0` = W.
  How to remember them: the three registers that start with "s" are the three Forth
  pointers, and W is the first argument register (NEXT hands W to the code-field routine).
  `sp`, `s0`, `s1` are also the registers no subroutine and no interrupt touches.
  Registers keep their ABI names in the source; there are no aliases.
- Scratch inside a primitive: `t0-t2`, `a1-a5`, `gp`, `tp`. Prefer `a1-a5` in new code: the
  2-byte forms of `lw` / `sw` through a pointer, `and` / `or` / `xor` / `sub` and `beqz` /
  `bnez` only take `s0`, `s1`, `a0-a5`. **`t0` is clobbered by PUSH / PUSHRSP / POPRSP /
  checkunderflow** (not by POP). **NEXT clobbers `a5`.** `ra` is for `call` / `ret` only.
- **Nothing may be stored below `sp`.** The QingKe V2 stacks its 48-byte interrupt frame at
  `sp` (hardware prologue, processor manual 3.4), and `sp` is the data stack. PUSH and
  PUSHRSP therefore move the pointer first, then store; to push `sp` itself, copy it to a
  register first (see `sp@`). `IRQ_FRAME` (48 bytes) stays free under the data stack for one
  frame, so it holds 52 cells and interrupts must not nest.
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
  `src/board/ch32v006f8u6/linker.ld`; confirm it says 16k).
  Currently 12,412 bytes (173 words). Report the size after every change.
- Flash 0x08004000-0x08006800: source-replay log (10 KiB).
- Flash 0x08006800-0x0800F800 (`USER_FLASH`..`FLASH_TOP`, 36 KiB): the application's own
  data, written a 256-byte page at a time with `fpage-erase ( page -- )` and
  `fpage-prog ( src page -- )`. Both words refuse any other address, so they cannot damage
  the kernel or the log. Planned use: the call log in the top 4 KiB (0x0800E800-0x0800F7FF,
  see `etc/answers.md`). The phonebook and the SMS stay on the SIM.
- RAM 0x20000000: the user dictionary grows up from here (`HERE`). It is **empty after
  boot**: every kernel word lives in flash.
  `FORTH_SIZE` = 0x1AC8 = **6,856 bytes** of dictionary budget (up to `LOGBUF`).
- RAM, top down: `DSP_TOP` 0x20002000, `RSP_TOP` 0x20001F00, `TIB_TOP` 0x20001E00,
  `TIB_BOTTOM` 0x20001D00 (256 B), `var_STATE` 0x20001CFC, `var_TOIN` 0x20001CF8,
  `var_HERE` 0x20001CF4, `var_LATEST` 0x20001CF0, then log bookkeeping, `var_BASE`
  0x20001CD8, `var_HLD`, `var_CONTEXT`, `var_CURRENT`, `var_VOCLINK` 0x20001CC8, `PAD`
  0x20001BC8, `LOGBUF` 0x20001AC8. RAM-variable cells are named `var_X` as in jonesforth, so
  the bare names stay free for word labels; `TIB_BOTTOM` is the start of the input buffer.
  New buffers (modem line, display frame, SD sectors) are carved out below `LOGBUF` the
  same way, in `01-variables-constants.s`; each one shrinks `FORTH_SIZE`.

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

## Source-replay log

`+log` / `-log` turn logging on and off, `wipe` erases it. Successful input lines are
appended to flash and replayed at boot. A line that errors abandons the replay.
Definitions are batched atomically in `LOGBUF`.

An append rewrites each 256-byte page it touches (`log_commit` in `src/12-flash-log.s`):
copy the page into the TIB (free at commit time), merge the new bytes, erase the page
unless it reads all 0xFF, program it with `fpage_prog`, read it back (a mismatch prints
`? log off`). A power cut between erase and program loses that page's earlier lines;
replay then stops there (PD4 skips it). Logged lines end with " \n" (the newline became
a space) and batches are padded to even length for `log_scan`.

## Build, test, flash

Run from the repo root:

    make                              # sixforths.elf / .bin / .hex / .dump
    riscv64-unknown-elf-size sixforths.elf   # kernel size; text must stay under 16384
    python3 emulators/test_fotrh.py   # boots sixforths.bin in the emulator, loads prelude.f, runs all tests
    python3 emulators/check_threads.py  # compares the threads in src/10-forth-words.s with the compiler's output

The Makefile runs `riscv64-unknown-elf-as -g -march=rv32ec_zicsr_zmmul` with
`-I src/board/ch32v006f8u6 -I src/mcu/ch32v006 -I src`, then
`riscv64-unknown-elf-ld -m elf32lriscv -T src/board/ch32v006f8u6/linker.ld`, then
`objcopy`. The `.o` depends on every `src/*.s`, so a new `.s` file in `src/` is picked up
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
defines lives in RAM, so a reset loses it unless `+log` was on.

Layout:
- `sixforths.s` (repo root) is the top-level file. It includes `board.s`, `mcu.s`, then
  `src/01-*.s` ... `src/13-ticks.s` **in that order**. The dictionary follows the
  include order, and `.equ last_word, link` after the last include marks its end. It is
  searched from the end, so words in later files are found first.
- `src/board/ch32v006f8u6/` holds `board.s` and `linker.ld`; `src/mcu/ch32v006/` holds
  `mcu.s` (pin and register equates). Folder names are singular (`board`, `mcu`).
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
- `src/12-flash-log.s` holds the source log and the user flash page words.
- `src/13-ticks.s` holds `ticks` and `ms` (SysTick, polled).
- `emulators/` holds `rv32emu.py` (the owner's RV32EC emulator: alignment, RV32E register
  use, FPEC sequencing and illegal instructions all fault), `harness.py` (boots
  `../sixforths.bin` in it), `test_fotrh.py` (the tests; it loads `../prelude.f`) and
  `check_threads.py`. Tests must pass before a change is called done.
- `prelude.f` (repo root) is the place for Forth words that are still being developed. It
  is empty now: its 57 words moved into flash. A word tried out there (or at the console
  with `+log`) is moved into `08-primitives.s` or `10-forth-words.s` once it is stable.
- `etc/answers.md` holds the design decisions behind the kernel layout and the plan for the
  phone (registers, flash, call log format, vocabularies, key input). Read it before
  starting on a driver.
- `docs/` holds reference PDFs (CH32V00xRM register manual, CH32V006 datasheet, pinout, the
  A7670X HAT schematic, Moving Forth parts 1-8). Read only the pages you need.
  `docs/docs-from-claude/` holds files handed over from chat; `old-docs/` looks like older
  notes. Neither is source.
- `openocd.cfg`, `ft232r.cfg`, `debug.gdb` look like an older OpenOCD / gdb debugging
  setup. Ask the owner before using them; flashing normally goes through minichlink.

## How to work here

1. After **every** change: run `make`, then `python3 emulators/test_fotrh.py`, and after a
   change to `src/10-forth-words.s` also `python3 emulators/check_threads.py`. Report the
   kernel size against the 16 KiB cap and any test that fails. If a build or test
   fails, fix the cause; do not delete or loosen a test to make it pass.
2. Add a test in `emulators/test_fotrh.py` for every new word, including edge cases (negative
   numbers, zero, overflow, divide by zero, overlapping `move`).
3. **Never flash, wipe, or erase flash without asking first.** Before anything that
   writes the log region, read it back and tell the owner what is there. Explain in
   one sentence what the command will do to the board.
4. Hardware tests over UART: sync on the echo after every line; save and restore
   `here` / `latest`; run the Forth words `s0 sp!` between tests (Forth `s0` = data-stack base, unrelated to
   register `s0`); start from a known state (log wiped
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
error recovery by the hidden flag, vocabularies. Not yet run on the board: `fpage-erase` /
`fpage-prog`.

Still open from before:
- The log-full path has not been tested on the board. Note the log starts with `+log`, so
  every boot turns logging on again and every typed line is saved; `-log` is not logged.
- A pyserial backend for `emulators/test_fotrh.py`, so the same tests run against the real
  board (and against the emulator through a fake port).
- Optional: `?do`.

## Phase 2: the phone hardware

Work this list from the top, **one item per session**, and stop after each for the owner
to test on the board. The reasons behind each choice are in `etc/answers.md`.

Rules for all of it:
- The emulator has no USART2, DMA, TIMx or interrupt model (its SysTick counts one HCLK
  cycle per instruction and faults on STIE, STRE, SR and CMPLR). Before writing a driver, add
  the smallest model of that device to `emulators/rv32emu.py` so the words can be tested
  there, and say plainly which part can only be checked on the board.
- Look every register address and bit up in `docs/ch32v006/CH32V00XRM.PDF` (only the pages
  needed) and quote the section in a comment. Do not write a register from memory.
- A device gets its own numbered file with its machine code and its words (`14-modem.s`,
  `15-display.s`, ...); pin and register equates go to `mcu.s`. Keep one pin table in this
  file once pins are assigned (the QFN20 has few: count them before promising one).
- Interrupts: at most **one**, and it must not nest. Its routine may use only `ra`,
  `t0-t2`, `a0-a5` (the hardware prologue saves exactly those) and must not touch `sp`,
  `s0`, `s1`, `gp`, `tp`. The vector table in `sixforths.s` has four entries; an interrupt
  needs it extended to its number. HPE and the vector mode are set in CSRs described in
  `docs/ch32v006/QingKeV2_Processor_Manual.PDF` chapter 3.
- Everything that waits (for the modem, for a key) needs a timeout. A phone must not hang.

The steps:
1. **First flash of this kernel.** Ask first (rule 3 above). The log on the board still
   holds the old prelude: it would be compiled into RAM on top of the same words in
   flash, so read the log back, show it, and `wipe` it with the owner's consent. Then run
   by hand: `words`, `5 6 + .`, `: sq dup * ; 7 sq .`, `3 allot nosuchword` (must print
   `?`, not a `T...` trap line), `vocabulary edit edit definitions : k3 70 emit ;
   forth definitions edit k3 forth`, and a `+log` / reset / replay round trip.
   **Done 2026-11-12**: all passed, the replay after `reboot` and after `minichlink -b`
   matched the emulator byte for byte, and the board's log is wiped again. Learned:
   `minichlink -w` rewrites only the pages it writes, so **the log survives a kernel
   reflash** and replays on the new kernel's first boot (send `wipe` as the first line, or
   hold PD4, when the old log does not suit the new kernel). minichlink sometimes prints
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
4. **Vectored `emit` and `key`.** One RAM cell holds the routine `emit`, `type`, `."` and
   `.` send through (console, modem or display), another the one `key` and `key?` read from
   (console, `mkey`, or the keypad's characters from step 6). `mkey?` `mkey` `memit` stay as
   words of their own: the phone's main loop polls the console, the modem and the keys side
   by side.
   **Errors must work without a console.** On the finished phone nothing is connected to
   USART1, so an error must not fall back to the console REPL (the owner, 2026-11-12).
   `reset` restarts the word held in a RAM cell instead: the REPL by default (developing,
   with a PC attached), or the phone's main loop, which puts itself there when it starts
   (from the last line of the log). That word sets the vectors it needs and shows the
   error: the REPL on the console as now, the phone on the LED matrix (for example `?` and
   the word's name), cleared with a key. A trap still sends `T<mcause> <mepc>` to the
   console; on the phone it then resets the chip (later through the watchdog) instead of
   hanging. A REPL on the matrix and the 8 keys is possible later, but slow.
5. **Tick interrupt** (about every 2 ms): refresh one LED row
   (`docs/output/LED-matrix/Bitbang-LED-matrix.S` already keeps to the allowed registers),
   sample the 8 keys through the 74HC165, count time. This is the one interrupt.
6. **Key input**: chords are decoded on release (OR everything pressed since the first
   press, report it when all keys are up). Characters are entered with two strokes through
   a 64-byte table, `map[8 * first + second]`.
7. **Modes**: one vocabulary per mode (idle, dial, call, edit, ...), a variable that holds
   the current mode's vocabulary, and a handler that builds a name from the key mask
   (`k13` for keys 1 and 3) and looks it up with `find-name-in`, then in a common
   vocabulary. Do not switch CONTEXT from the key handler.
8. **Call log** in the user flash, 16-byte records (format in `etc/answers.md`).
