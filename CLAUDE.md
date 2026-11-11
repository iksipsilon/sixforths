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
  halfwords on real V006 silicon**; the emulator faults on it deliberately.
  Use fast page programming (FTER 64-byte page erase, FTPG page buffer with
  BUFRST / BUFLOAD) instead.
- Trap handler (`src/03-interrupts.s`) prints `T<mcause> <mepc>` in hex over UART and
  hangs. Traps enter at 0x0 like reset (`mtvec` = 0; the V2 needs a 1 KiB-aligned trap
  base): `_start` in `sixforths.s` sends a non-zero `mcause` to the handler. Do not put
  a `.balign 1024` back; it cost ~1.6 KB of padding. If the board prints that, the code did something illegal at that address.
- Holding **PD4 high at reset skips the source-replay log** (see below). This is the
  recovery switch if a bad log line stops the board booting.

## Forth architecture

- Registers: `sp` = data stack, `s0` = return stack, `s1` = IP, `a0` = W,
  `a1-a3` = X/Y/Z scratch, `a4`, `a5`, `gp`, `tp` = more scratch.
  **`t0` is clobbered by PUSH / POP / PUSHRSP / POPRSP / checkunderflow macros.**
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
  `base` (defined in `prelude.f`) only affects output words.
- CREATEd words are laid out `[header][cfa][DOES> slot][data]`.
  `dovar` / `docon` / `docol` / `xdoes` are the runtime code fields.

## Memory map (verify with `riscv64-unknown-elf-nm sixforths.elf`)

- Flash 0x00000000: kernel + `.rodata`, **must stay under 16 KiB** (`FLASH` `LENGTH` in
  `src/board/ch32v006f8u6/linker.ld`; confirm it says 16k).
  Currently 8,560 bytes. Report the size after every change.
- Flash 0x08004000-0x08006800: source-replay log (10 KiB). Space above that is
  reserved for the phonebook / SMS storage. Do not touch it casually.
- RAM 0x20000000: the user dictionary grows up from here (`HERE`).
  `FORTH_SIZE` = 0x1ADC = **6,876 bytes** of dictionary budget (up to `LOGBUF`).
- RAM, top down: `DSP_TOP` 0x20002000, `RSP_TOP` 0x20001F00, `TIB_TOP` 0x20001E00,
  `TIB_BOTTOM` 0x20001D00 (256 B), `var_STATE` 0x20001CFC, `var_TOIN` 0x20001CF8,
  `var_HERE` 0x20001CF4, `var_LATEST` 0x20001CF0, then log bookkeeping, `PAD` 0x20001BDC,
  `LOGBUF` 0x20001ADC. RAM-variable cells are named `var_X` as in jonesforth, so the bare
  names stay free for word labels; `TIB_BOTTOM` is the start of the input buffer.

## REPL quirks (they affect how tests and prelude files must be written)

- `(` ... `)` and `\` to end of line are swallowed **before** they reach the TIB.
  Never put them inside names or strings. A trailing `\ comment` merges the next line,
  so write comments on lines of their own.
- The TIB is 256 bytes: keep every source line under 250 characters.
- CR is ignored; ANSI escape sequences are swallowed; BS / DEL are handled.
- The interpreter does not read UART while it processes a line (the receiver holds
  only 1-2 bytes). Anything that feeds the board automatically must wait for the echo
  or prompt after each line.

## Source-replay log

`+log` / `-log` turn logging on and off, `wipe` erases it. Successful input lines are
appended to flash and replayed at boot. A line that errors abandons the replay.
Definitions are batched atomically in `LOGBUF`.

**Known bug: `fh_prog` in `src/12-flash-log.s` still uses halfword PG**, which the emulator
rejects (so `+log` faults in the emulator) and which is suspect on silicon.
Porting it to FTPG is the top open task.

## Build, test, flash

Run from the repo root:

    make                              # sixforths.elf / .bin / .hex / .dump
    riscv64-unknown-elf-size sixforths.elf   # kernel size; text must stay under 16384
    python3 emulators/test_fotrh.py   # boots sixforths.bin in the emulator, loads prelude.f, runs all tests

The Makefile runs `riscv64-unknown-elf-as -g -march=rv32ec_zicsr_zmmul` with
`-I src/board/ch32v006f8u6 -I src/mcu/ch32v006 -I src`, then
`riscv64-unknown-elf-ld -m elf32lriscv -T src/board/ch32v006f8u6/linker.ld`, then
`objcopy`. The `.o` depends on every `src/*.s`, so a new `.s` file in `src/` is picked up
automatically (add its `.include` to `sixforths.s`). Ubuntu package:
`binutils-riscv64-unknown-elf`. Build outputs are git-ignored.

Hardware (the board is plugged in through a WCH-LinkE, attached to WSL2 with usbipd-win):

    minichlink -w sixforths.bin flash -b    # program the chip and reboot
    picocom -b 115200 --imap lfcrlf --omap crlf /dev/ttyACM0   # talk to the REPL (Ctrl-A Ctrl-X to quit)

The two maps are needed: the board ends its lines with LF only, and it ignores CR,
so Enter (CR) must be sent as LF. `make term` runs the same picocom command.

Layout:
- `sixforths.s` (repo root) is the top-level file. It includes `board.s`, `mcu.s`, then
  `src/01-*.s` ... `src/13-ans-primitives.s` **in that order**. The dictionary follows the
  include order, and `.equ last_word, link` after the last include marks its end.
- `src/board/ch32v006f8u6/` holds `board.s` and `linker.ld`; `src/mcu/ch32v006/` holds
  `mcu.s` (pin and register equates). Folder names are singular (`board`, `mcu`).
- `src/13-ans-primitives.s` holds the ANS-style assembly words.
- `emulators/` holds `rv32emu.py` (the owner's RV32EC emulator: alignment, RV32E register
  use, FPEC sequencing and illegal instructions all fault), `harness.py` (boots
  `../sixforths.bin` in it) and `test_fotrh.py` (the tests; it loads `../prelude.f`).
  Tests must pass before a change is called done.
- `prelude.f` (repo root) is everything written in Forth on top of the primitives (control
  flow, defining words, number output, strings, `forget`, `dump`). It costs about 2.8 KB of
  RAM dictionary. Promoting stable prelude words into flash is a planned task; `prelude.f`
  may then move to `src/`.
- `docs/` holds reference PDFs (CH32V00xRM register manual, CH32V006 datasheet, pinout, the
  A7670X HAT schematic, Moving Forth parts 1-8). Read only the pages you need.
  `docs/docs-from-claude/` holds files handed over from chat; `old-docs/` looks like older
  notes. Neither is source.
- `openocd.cfg`, `ft232r.cfg`, `debug.gdb` look like an older OpenOCD / gdb debugging
  setup. Ask the owner before using them; flashing normally goes through minichlink.

## How to work here

1. After **every** change: run `make`, then `python3 emulators/test_fotrh.py`. Report the
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
5. Work on a feature branch (the current one is `extended-wordset`). Make small commits.
   Run `git log --oneline -20` first and match the existing commit message style.
   Never push without asking.
6. Match the existing assembly style and comments. Where the source marks deliberate
   differences from upstream FiveForths (look for `CH32V006 PORT:` comments), keep
   marking them the same way.
7. Prefer changing a small number of files at a time. If a task needs more than a few
   files, say so and propose the plan first.

## Open work

- Port `fh_prog` (called from `log_commit`) in `src/12-flash-log.s` to FTPG page-buffer
  programming; check that `fpage_erase` (already FTER) fits the same scheme. Get `+log`
  working in the emulator, then on the board.
- Add a pyserial backend to `emulators/test_fotrh.py` so the same tests run against the real
  board (and against the emulator through a fake port).
- A freeze script to turn stable prelude words into flash words.
- Optional: `?do`.
