# sixforths

A Forth operating system for a DIY LTE phone: an indirect-threaded Forth in RISC-V
assembly for the WCH CH32V006F8U6 microcontroller. The owner types Forth over UART; the
phone's features are Forth words.

Hardware around the MCU: Waveshare A7670E LTE Cat-1 HAT (driven with AT commands
over UART), 8 pushbuttons, a microphone, a speaker, an LED matrix (5x32 / 5x42,
MBI5024 shift-register chain), and an SD card over SPI for call recordings.

The owner knows RISC-V assembly and Forth well, prefers the command line and vi,
and is **new to Claude Code**: explain what you are about to do in plain words,
keep steps small, and say what a command does before running anything that touches
hardware.

This file describes the kernel as it is. How it got here is in `etc/history.md`, which
no session needs to read.

## The chip (these facts cause most bugs)

- QingKe V2C core: **RV32EC + Zmmul + Zicsr**. 62 KiB flash, 8 KiB SRAM, HSI 24 MHz.
- **RV32E has only x0-x15.** Never use s2-s11 or t3-t6. The assembler flag is
  `-march=rv32ec_zicsr_zmmul` (the ABI is then ilp32e).
- **Misaligned `lw` / `sw` / `lhu` trap.** Put `.balign CELL` before any data read with
  `lw`. The `number` routine uses byte loads on purpose. Code needs no `.balign`: an even
  address is enough, and it has one already, except right after a string (`.balign 2`,
  as before `boot`). Only `trap_handler` and `tick_isr` keep a `.balign CELL`: the
  hardware enters them through the vector table, the manual does not say how they must
  be aligned, and the board has only run them 4-byte aligned.
- **Zmmul has `mul` only.** No `div`, `rem`, `mulh`, `mulhu`. `um*` is built from
  16x16 `mul`s; `um/mod` is shift-and-subtract. The emulator also lacks `mulh*`.
- The chip starts at HCLK = 8 MHz: after reset `RCC_CFGR0` is 0x20, HPRE = SYSCLK / 3
  (the manual says so, and the board gave the same when read halted at reset).
  `uart_init` (`src/mcu.s`) sets 1 flash wait state, then writes CFGR0 wholesale to 0
  for 24 MHz. The reasons are in its comments.
- Standard halfword flash programming (PG) reportedly **corrupts neighbouring
  halfwords on real V006 silicon**. Use fast page operations instead, and note the
  **V006 fast page is 256 bytes** (the CH32V003's is 64): FTER erases a page, FTPG
  programs one through the page buffer (BUFRST, 64 x word store + BUFLOAD, FLASH_ADDR,
  STRT; reference manual 18.4.5). The emulator faults on PG, on a half-loaded buffer,
  and on programming a page that is not erased.
- The trap handler (`trap_handler` in `src/03-traps.s`) prints `T<mcause> <mepc>` in hex
  on the console and hangs with all state intact, but a debugger usually resets the chip
  when it connects (see "What minichlink does"). If the board prints that, the code did
  something illegal at that address. Traps use a vector table at 0x0 (`_start` in
  `sixforths.s`, `mtvec` = 3; the V2 needs the table 1 KiB aligned, and 0x0 is): entry 0
  = reset jump, 2 = NMI, 3 = every exception, 12 = the SysTick tick (`tick_isr`). Entries
  0-12 exist; enabling another interrupt needs the table extended to its number. **Never
  tell reset from a trap by `mcause`: on silicon it is not 0 after reset** (the board
  read 0x800000D9).
- Holding **PD4 high at reset keeps line 0 from loading** (see "Source lines in flash"
  below). This is the recovery switch if a bad line 0 stops the board booting. On the
  owner's WeAct board PD4 follows PD5 (the console's TX) through the USB D- line (the
  parts the schematic calls SB3 and SB4: 33 Ω and 1.5 kΩ). PD5 is high as the TX and
  also when released (the WCH-LinkE's RX pulls it up), so `gpio_init` samples PD4 with
  PD5 driven low for only ~0.5 us (7 instructions; a pulse of ~3 us shows up as a stray
  character before the banner); never read PD4 any other way. The emulator models this
  with `weact_bridge = True`.

## Forth architecture

- Registers: `s0` = DSP (data stack), `tp` = RSP (return stack), `s1` = IP, `a0` = W
  (NEXT hands W to the code-field routine). **`sp` is the machine stack**, not a Forth
  stack: the QingKe V2 stacks its 48-byte interrupt frame there (hardware prologue,
  processor manual 3.4), and nested subroutines keep `ra` there
  (`addi sp, sp, -CELL` / `sw ra, 0(sp)` ... `lw ra, 0(sp)` / `addi sp, sp, CELL`).
  `s0`, `tp`, `s1` are the registers no subroutine and no interrupt touches.
  Registers keep their ABI names in the source; there are no aliases.
- Scratch inside a primitive: `t0-t2`, `a1-a5`, `gp`. Prefer `a1-a5` in new code: the
  2-byte forms of `lw` / `sw` through a pointer (the data stack's `s0` included), `and` /
  `or` / `xor` / `sub` and `beqz` / `bnez` only take `s0`, `s1`, `a0-a5`, for both
  registers. **`t0` is clobbered by PUSH / PUSHRSP / POPRSP / checkunderflow** (not by
  POP). **NEXT clobbers `a5`.** `ra` is for `call` / `ret` only.
- The machine stack is 96 bytes (`MSTACK_SIZE`: one frame + 12 cells), under the
  variables and above `PAD` (nothing checks `sp` on the chip: an overrun lands in
  scratch, not in STATE / HERE / LATEST); `boot` and `reset` empty it (`li t0, MSP_TOP` /
  `mv sp, t0`: `sp` gets its value in one instruction). A primitive must leave `sp` as it
  found it; a jump to an `err_*` label from inside a subroutine is fine, because `reset`
  empties the stack. Interrupts must not nest. PUSH and PUSHRSP move the pointer first,
  then store, so to push `s0` itself copy it to a register first (see `sp@`). The
  emulator faults if an interrupt finds `sp` outside the machine stack or without room
  for a frame.
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
- Every cell is appended by `comma` (`05-internal-functions.s`): the word `,`, a word or a
  number the interpreter compiles, the EXIT of `;`, the literal of `'`. It checks for a
  full dictionary, so its callers do not.
- HERE may be unaligned after `c,` or an odd `allot`; a misaligned `sw` would trap. `:`,
  `create` and the error path round it up themselves, and so does `comma` while
  interpreting (the bytes are data: `create x 65 c, 1 ,`). **While a definition is
  compiled `comma` does not round up**: the thread would get a gap that the inner
  interpreter runs as a word, so an unaligned HERE is an error there (`?`, the definition
  is dropped). Bytes that belong in a thread stand behind a word that steps IP over them
  (as `litstring` does) and end with `align`. An aligned gap (`[ 4 allot ]` with no such
  word) cannot be told from data: it compiles, and crashes when the word runs.
- No word stores into the header of a kernel word (it is in flash). `;` ends the definition
  that is open, which it knows by the hidden flag of the newest word; with none open it is
  an error and appends nothing. `immediate` and `xdoes` (the runtime of `does>`) are an
  error unless the newest word is in RAM.
- After every error `reset` calls `abandon_def`: if the newest word is still hidden (a word
  is hidden exactly while it is compiled) it is unlinked and HERE moves back. `reset` also
  puts CONTEXT and CURRENT back to FORTH, and the I/O vectors back to the console.
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
  Currently 13,464 bytes (184 words). Report the size after every change.
- Flash 0x08004000-0x08006800 (`LINES_BASE`..`LINES_TOP`, 10 KiB): 160 source lines of
  64 bytes (see "Source lines in flash").
- Flash 0x08006800-0x0800F800 (`USER_FLASH`..`FLASH_TOP`, 36 KiB): the application's own
  data, written a 256-byte page at a time with `fpage-erase ( page -- )` and
  `fpage-prog ( src page -- )`. Both words refuse any other address, so they cannot damage
  the kernel or the source lines. On the board an erase takes 3.02 ms and a program
  2.04 ms. Planned use: the call log in the top 4 KiB
  (0x0800E800-0x0800F7FF, see `etc/answers.md`). The phonebook and the SMS stay on the SIM
  for now; they may move to the user flash or the SD card later, depending on how much the
  SIM holds (not known yet, see `etc/answers.md` section 9).
- RAM 0x20000000: the user dictionary grows up from here (`HERE`). It is **empty after
  boot**: every kernel word lives in flash.
  `FORTH_SIZE` = 0x1898 = **6,296 bytes** of dictionary budget, up to `DICT_TOP` (which is
  `FRAME`).
- RAM, top down: `DSP_TOP` 0x20002000 (the data stack, `STACK_SIZE` = 256 B = 64 cells),
  `RSP_TOP` 0x20001F00 (the return stack, the same size), `TIB_TOP` 0x20001E00,
  `TIB_BOTTOM` 0x20001D00 (`TIB_SIZE` = 256 B), then the 16 variable cells:
  `var_STATE` 0x20001CFC, `var_TOIN` 0x20001CF8, `var_HERE` 0x20001CF4, `var_LATEST`
  0x20001CF0, `var_SRC` and `var_SRCEND` (the lines being loaded), `var_BASE` 0x20001CE4,
  `var_HLD`, `var_CONTEXT`, `var_CURRENT`, `var_VOCLINK` 0x20001CD4, `var_MRD`,
  `var_MTIMEOUT` 0x20001CCC, `var_OUT`, `var_IN` 0x20001CC4 (the I/O vectors), `var_IRQS`
  0x20001CC0 = `MSP_TOP` (the machine stack, 96 bytes, down to `MSP_BOTTOM` 0x20001C60),
  `PAD` 0x20001B60, `PAGEBUF` 0x20001A60 (one flash page), `MRING` 0x20001960 (the modem's
  256-byte receive ring), `MLINE` 0x200018C0 (160 B, one line of the modem's answer) and
  `FRAME` 0x20001898 (40 B, the display's pixels: 5 rows of 2 cells) = `DICT_TOP`.
  `MLINE` and `FRAME` are reserved; no code uses them yet.
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
  Never put them inside names or strings. The newline that ends a comment ends the line
  as usual: what stands before the comment runs, and a line that is only a comment gets
  its `ok`. A `(` comment also ends at the end of its line, so it cannot span lines.
- The TIB is 256 bytes and its last byte always stays 0 (the end mark `token` stops at),
  so **a line holds at most 254 characters**; a longer one gets `? tib full`. Keep every
  source line under 250 characters.
- CR is ignored; ANSI escape sequences are swallowed; BS / DEL erase the last character,
  on the screen and in the TIB. The LF that ends a line is echoed, so its output and `ok`
  start on the next line (tests expect e.g. `"65 emit\nA"`).
- The interpreter does not read UART while it processes a line (the receiver holds
  only 1-2 bytes). Anything that feeds the board automatically must wait for the echo
  or prompt after each line.

## Source lines in flash

Flash holds 160 numbered lines; nothing is saved automatically. Each line has a 64-byte
slot: the text (up to 63 characters), a newline, then unused bytes that stay 0xFF. A slot
that was never written is all 0xFF and counts as an empty line.

- `n p text` puts the rest of the input line into line n, in flash at once (`20 p : sq dup * ;`).
  It copies the line's page (4 lines) to `PAGEBUF`, rebuilds the slot, erases the page,
  programs it and reads it back (`? flash` if that differs). It prints `?` and writes
  nothing if n is not 0-159 or the text is over 63 characters. `n p` alone empties a line.
  On the board one `p` takes about 5 ms from the echo to `ok`, and ten in a row lost 5 of
  398 ticks.
- `a b list` prints lines a to b with their numbers.
- `a b load` interprets lines a to b as if typed (they echo, each gets its `ok`). The
  lines are read once the current input line is finished, so **`load` goes last on its
  line**; a `load` in a loaded line replaces the range and does not come back. An error
  in a loaded line abandons the rest.
- `n line` gives the slot's address. `wipe` erases all 160 lines (117 ms on the board).
- **Line 0 is interpreted at boot** unless PD4 is held. It usually holds a `load`.
- Comments never reach a line (the REPL swallows them first). The master copy of the
  source is a file on the PC; `grep -v -e '^\\' -e '^ *$' file.f | awk '{ print NR+3, "p", $0 }'`
  numbers it from line 4. The `grep` matters: `7 p \ comment` is `7 p` alone, which
  empties line 7 and uses up a line number for nothing.
- Inside: `uart_get` (`04-io-helpers.s`) takes its bytes from `var_SRC` up to `var_SRCEND`
  while `var_SRC` is not 0, skipping 0xFF; `reset` clears it. `fpage-erase` / `fpage-prog`
  refuse the lines, and `p` refuses everything else.
- A power cut between erase and program loses the 4 lines of that page; the other pages
  still load.
- `etc/source-lines.md` explains all of this in full.

## Time, modem, I/O vectors

Time (`src/12-ticks.s`):
- `ticks ( -- u )` is the SysTick count on HCLK/8: 3000 per ms (`STK_TICKS_PER_MS`),
  wrapping every 23.9 min; `ticks t0 -` is the time since t0. The counter runs free and
  is read by polling. Writing `STK_CNTL` works; after `reboot` the count starts from 0.
- `ms ( n -- )` treats n as signed (n <= 0 returns at once). On the board `5000 ms` took
  4.97-4.99 s by the PC's clock: the HSI runs 0.2-0.6% fast.
- The tick is SysTick's compare interrupt every `TICK_PERIOD` (6000 ticks = 2 ms),
  `tick_isr`. It is **the one interrupt**. It leaves the counter running, so `ticks` `ms`
  `mkey` are not affected. `tick_isr` puts the next compare one period on, or one period
  after now when it ran late (flash work holds the core up; a compare in the past would
  not match again for 23.9 minutes), and counts `irqs ( -- n )`. HPE is on, so traps
  stack a frame too. On the board: 500 ticks in 1000 ms; 16 page erases (46.9 ms) let 16
  late ticks through and the tick was back at 500 a second at once.

Modem (`src/13-modem.s`):
- USART2, received by DMA channel 7 into the 256-byte ring `MRING`, no interrupt: the
  main loop polls. USART2 can only be TX = PD2, RX = PD3 on the QFN20 (`AFIO_PCFR1`
  USART2_RM = 011; the other remaps need pins it lacks, or SWIO).
- `mkey? ( -- flag )`, `mkey ( -- c | -1 )` (waits at most `mtimeout` ms, 1000 at boot;
  -1 if nothing came), `memit ( c -- )`, `mtimeout ( -- addr )`. A reader that falls a
  whole ring behind loses bytes without an error: an unread 300-byte burst leaves the
  last 44. Unread bytes survive an error.
- **The DMA keeps storing bytes while a flash page is erased** (the core stands still for
  about 3 ms), so the call log may be written while the modem talks. Measured on the
  board with USART1 RX through DMA channel 5, the same controller: 2,048 streamed bytes
  while 16 pages were erased, 543 of them during the 46.8 ms of erasing (2.92 ms a page),
  no overrun, none wrong; SysTick kept counting. Page programming (FTPG) stalls the core
  for 2.04 ms; whether the DMA keeps storing bytes meanwhile was not measured.
- So far the modem words have only talked to themselves, through a wire from D2 to D3.
  Before connecting the A7670E, read the HAT schematic in `docs/A7670X` for its UART
  voltage.

I/O vectors (`src/04-io-helpers.s`, the words in `08-primitives.s` and `13-modem.s`):
- `var_OUT` holds the routine `emit` `space` `cr` `type` `words` (and so `.` `u.` `."`
  `.s` `dump`) send through; `var_IN` points at an input table (get, ready) that `key`
  and `key?` use. `>console` `>modem` and `<console` `<modem` set them; the keypad and
  the display will add theirs. The modem's `key` gives -1 after `mtimeout` ms.
- The console's `key` and `key?` look at the UART only. The lines being loaded are read
  by the interpreter alone, so a `key` in a loaded line waits for the keyboard and the
  lines after it stay whole (a main loop started from a loaded line can poll the console).
- The REPL's echo, `ok`, the error messages, the banner and the trap line always use the
  console, and `reset` (boot and every error) sets both vectors back to the console.
- `mkey?` `mkey` `memit` stay as words of their own: the phone's main loop polls the
  console, the modem and the keys side by side.

## Build, test, flash

Run from the repo root:

    make                              # sixforths.elf / .bin / .hex / .dump
    riscv64-unknown-elf-size sixforths.elf   # kernel size; text must stay under 16384
    python3 emulators/test_sixforths.py   # boots sixforths.bin in the emulator, loads prelude.f, runs all tests
    python3 emulators/check_threads.py  # compares the threads in src/10-forth-words.s with the compiler's output

The Makefile runs `riscv64-unknown-elf-as -g -march=rv32ec_zicsr_zmmul` with
`-I src`, then `riscv64-unknown-elf-ld -m elf32lriscv -T linker.ld`, then `objcopy`. The
`.o` depends on every `src/*.s`, so a new `.s` file in `src/` is picked up
automatically (add its `.include` to `sixforths.s`). Ubuntu package:
`binutils-riscv64-unknown-elf`. Build outputs are git-ignored.

Hardware (the board is plugged in through a WCH-LinkE, attached to WSL2 with usbipd-win):

    minichlink -w sixforths.bin flash -b    # program the chip and reboot
    minichlink -r <file> 0x08000000 0xF800  # read the whole flash back (read only), and then
    minichlink -b                           # restart the chip: -r leaves the core halted
    minichlink -e                           # or resume the halted core without a reset
    picocom -b 115200 --imap lfcrlf --omap crlf --send-cmd "ascii-xfr -sv -l 100" /dev/ttyACM0
                                            # talk to the REPL (Ctrl-A Ctrl-X to quit)

The two maps are needed: the board ends its lines with LF only, and it ignores CR,
so Enter (CR) must be sent as LF. `make term` runs the same picocom command, and
`make flash` the `minichlink -w` line (it programs the `sixforths.bin` that is there; it
does not build first). To send a
Forth source file, press Ctrl-A Ctrl-S and give its name: ascii-xfr sends one line, then
waits 100 ms (the board does not read the UART while it processes a line). What it
defines lives in RAM, so a reset loses it; lines put with `p` stay in flash.

What minichlink does, as seen on the board:
- `minichlink -w` rewrites only the pages it writes, so **the source lines survive a
  kernel reflash** and line 0 loads on the new kernel's first boot. Send `wipe` as the
  first line, or hold PD4, when the old lines do not suit the new kernel.
- It also keeps the old bytes after the end of the image in the last page it writes. Do
  not assume the flash after the kernel is erased.
- Flashing prints one stray byte before the banner; a plain `minichlink -b` reset does
  not.
- `minichlink -r` halts the core and does not resume it. Always follow it with
  `minichlink -b` (or `minichlink -e`).
- After `minichlink -r` and `minichlink -b` the first line sent once came back with `?`:
  the PC had received a stray byte (`ò`) before it, and the line was not understood, as
  if that byte sat in the TIB. A second time it did not happen. A test script sends an
  empty line first.
- **Only the first connection after a power-up reliably leaves the chip running.** Later
  connections usually print `link error, nothing connected to linker` five times
  ("Trying to put processor in hold and retrying"), then work, and the chip has been
  reset (`irqs` starts again from 0); once a reset followed a connection without that
  message. So RAM is only trustworthy in the first read after a power-up. gdb through
  `minichlink -G` also reset the chip, and could not detach (T05).
- `minichlink -e` resumes a halted core without a reset, when it does not hit the link
  error.
- To stop a hung minichlink or picocom, kill it by PID: `pkill -f <pattern>` also kills
  the shell that runs it, whose command line contains the pattern.
- A register's value at reset can be read without touching flash:
  `minichlink -a -r <file> 0x40021000 0x28` resets the chip, halts it before its first
  instruction and reads memory (here the ten RCC registers); `minichlink -b` then
  restarts it. `RCC_PB2PCENR` reading 0 shows that `uart_init` has not run yet.
- WSL may need the WCH-LinkE attached again (`usbipd attach --wsl --busid <id>` on
  Windows; `usbipd list` shows the id).

Layout:
- `sixforths.s` (repo root) is the top-level file. It includes `src/mcu.s`, then
  `src/01-*.s` ... `src/13-modem.s` **in that order**. The dictionary follows the
  include order, and `.equ last_word, link` after the last include marks its end. It is
  searched from the end, so words in later files are found first.
- `src/mcu.s` holds the chip's constants, one section per peripheral (RAM, clock, port D
  and pin remap, USART, DMA, flash controller, SysTick and the tick), each with its
  section of the reference manual, and `uart_init` / `gpio_init`. `linker.ld` (repo root)
  holds the memory regions. Nothing is placed in its RAM region, but keep its `LENGTH`
  equal to `RAM_SIZE`.
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
- `src/11-flash.s` holds the FPEC routines, the source lines (`line` `p` `load` `wipe`;
  `list` is a thread in `10-forth-words.s`) and the user flash page words.
- `src/12-ticks.s` holds `ticks` and `ms` (SysTick, polled), the tick interrupt `tick_isr`
  and `irqs`.
- `src/13-modem.s` holds the modem UART: USART2 received by DMA into `MRING`, and the
  words `mkey?` `mkey` `memit` `mtimeout` `>modem` `<modem`.
- `emulators/` holds `rv32emu.py` (the owner's RV32EC emulator: alignment, RV32E register
  use, FPEC sequencing and illegal instructions all fault), `harness.py` (boots
  `../sixforths.bin` in it), `test_sixforths.py` (the tests; it loads `../prelude.f`) and
  `check_threads.py`. Tests must pass before a change is called done.
- `prelude.f` (repo root) is the place for Forth words that are still being developed. It
  is empty now. A word tried out there (or kept in the flash lines with `p`) is moved
  into `08-primitives.s` or `10-forth-words.s` once it is stable.
- `etc/board.py` talks to the board over the UART for hardware tests: it sends Forth
  lines and waits for each echo and `ok` (its docstring has the commands).
- `etc/source-lines.md` explains the source lines in full: use, what happens in flash and
  RAM, the reasons for the structure, the comparison with classical blocks.
- `etc/answers.md` holds the design decisions behind the kernel layout and the plan for the
  phone (registers, flash, call log format, vocabularies, key input). Read it before
  starting on a driver.
- `etc/history.md` holds what is no longer true: where the kernel came from, and the
  dated reports of the steps that are done. `LICENSE` holds the MIT notice the kernel
  must carry.
- `docs/` holds reference PDFs (CH32V00xRM register manual, CH32V006 datasheet, pinout, the
  A7670X HAT schematic, Moving Forth parts 1-8). Read only the pages you need;
  `pdftotext -layout` into the scratchpad makes the manual searchable.
  `docs/docs-from-claude/` holds files handed over from chat. Neither is source.
- There is no README: this file is the description of the project.

## How to work here

1. After **every** change: run `make`, then `python3 emulators/test_sixforths.py`, and after a
   change to `src/10-forth-words.s` also `python3 emulators/check_threads.py`. Report the
   kernel size against the 16 KiB cap and any test that fails. If a build or test
   fails, fix the cause; do not delete or loosen a test to make it pass. A change that
   should not alter the kernel (comments, names) is proven by an unchanged
   `sha256sum sixforths.bin`.
2. Add a test in `emulators/test_sixforths.py` for every new word, including edge cases (negative
   numbers, zero, overflow, divide by zero, overlapping `move`). For a bug fix, write the
   test first and see it fail.
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
5. Work on a feature branch (the current one is `kernel-phase1`). Make small commits.
   Run `git log --oneline -20` first and match the existing commit message style.
   Never push without asking.
6. Match the existing assembly style. **Comments say what the code does and why it must
   be so on this chip, as it is now.** No history in the source or in this file: not what
   the code used to be, not what it was ported from, no dates of changes. That goes into
   the commit message, and a story worth keeping into `etc/history.md`. A measured
   hardware fact is not history: keep it where it explains the code.
7. Prefer changing a small number of files at a time. If a task needs more than a few
   files, say so and propose the plan first.

## Pins in use

QFN20 pin numbers from the datasheet's V006F8U7 column; the board's header labels the
pins D1 ... D6; its schematic is `docs/ch32v006/CH32V00xFxUx_Pinout.pdf`. The QFN20 has
few pins: count them before promising one.

| Pin | QFN | Use |
|---|---|---|
| PD1 | 15 | SWIO, the debug pin minichlink uses |
| PD2 | 16 | USART2 TX, to the modem's RX |
| PD3 | 17 | USART2 RX, from the modem's TX (pull-up). On the WeAct board it is also joined to the USB-C D+ line (33 Ω, SB2 in the schematic): keep the board's USB-C socket unplugged |
| PD4 | 18 | skip button (high at reset: line 0 is not loaded); follows PD5 through the USB D- line on the WeAct board |
| PD5 | 19 | USART1 TX, the console |
| PD6 | 20 | USART1 RX, the console (pull-up: while the WCH-LinkE powers up, its TX does not drive PD6, and a floating PD6 picks up PD5 next to it) |

Planned for the LED rows (step 5b): PC0, PC2, PA1, PA2.

The WCH-LinkE is wired to the board like this: SWDIO to PD1, 3V3 and GND; the LinkE's
RX to PD5 (the console's TX), the LinkE's TX to PD6 (the console's RX).

## The board now

- It runs commit `f91b7cc` (13,464 bytes), the kernel in the repo.
- Checked on the board on `f91b7cc` (the check in `xdoes`): on the fresh board `xdoes`,
  `xdoes` in an empty vocabulary and a `does>` word without `create` run in an empty
  vocabulary each print `?`, and `here` stays at `RAM_BASE`; `does>` (a constant, an
  array, a word made in a vocabulary), the tick (50 in 100 ms), `reboot`, `words` (184
  names); the read-back showed the kernel equal to `sixforths.bin`, the lines and the
  user flash empty.
- Checked on the board on `ba2cb4e` (the checks in `;` and `immediate`): on the fresh
  board `;`, `immediate`, `] ;` and `;` in an empty vocabulary each print `?`; a `;` with
  no definition open leaves `here` where it was; `: sq dup * ;`, `immediate` on a RAM
  word, an unaligned HERE in a definition (`?`), the tick (50 in 100 ms), `reboot`; the
  read-back showed the kernel equal to `sixforths.bin`, the lines and the user flash
  empty.
- Its source lines and its user flash are empty (all 0xFF, read back). A wire joins D2
  and D3 (the USART2 loopback; D2 is driven as an output at every boot) and the board's
  USB-C socket is unplugged. Nothing else is connected.
- Before trusting any of this after a pause: `make`, run the tests, and read the board's
  flash back to see what it really holds.
- Checked on the board on `6161c34` (`comma`; nearly every routine has moved since
  `3a4d650`):
  - An unaligned HERE while compiling prints `?` where older kernels trapped: a word, a
    number, `;`, `'` and `if` after `[ 3 allot ]` or `[ 65 c, ]`, a number after a `then`
    at an unaligned HERE, and the same in a loaded line (the lines after it are
    abandoned). The word is gone, `here` and `latest` are back. Bytes behind `litstring`
    that end with `align` work; `,` after `c,` rounds up.
  - The compiler: words, numbers, `'` `[']`, `do` `loop`, `if` `else` `then`, `begin`
    `until`, `."` `s"`, `variable` `constant` `does>`, `literal` `recurse`, a definition
    over two typed lines and one over two loaded lines, a vocabulary.
  - A full dictionary: at the second cell of a number, at `;`, in the header (each
    prints `? memory full` and the word is gone); `: zy dup ;` fits in 20 bytes exactly
    and not in 16.
  - Besides: an error with 3 cells on the stack, `3 allot nosuchword`, `words` (184
    names), the tick (50 in 100 ms), `memit` `mkey` `>modem` through the D2-D3 wire,
    `/mod` `um*` `hex`, `p` `list` `load` `wipe`, `reboot`; the read-back showed the
    kernel equal to `sixforths.bin`, the lines and the user flash empty.
- Checked on the board on `3a4d650`, which differs from `e4e4587` in the two things
  tested here:
  - Comments: what stands before a `\` comment runs when its line ends, a line that is
    only a comment gets its `ok`, an unclosed `(` ends with its line, a definition over
    two lines with both kinds; `n p \ comment` empties line n and the next line is not
    stored.
  - `key`: at the console it waits for a character; in a loaded line it waits for the
    console too and the line after it stays whole (`key emit` in line 50, `65 emit` in
    line 51). `key?` with nothing waiting gives 0.
  - Besides: DEL, an error, the tick (50 in 100 ms), `wipe`, `reboot`; the read-back
    showed the kernel equal to `sixforths.bin`, the lines and the user flash empty.
- Checked on the board on `e4e4587`:
  - Boot, and the first line after a power-up (3 of 3 power-ups left the TIB empty).
  - Errors: one with 3 cells on the stack and one inside a definition (both leave
    `depth` 0, and the half-made word is gone); `3 allot nosuchword`,
    `0 rp! nosuchword` and wrong `sp!` / `rp!` (each prints `?`, not a trap line).
  - The input line: 254 characters run, 255 give `? tib full` and the next line
    works; BS and DEL leave nothing of the erased characters in the TIB; `parse-name`
    on a token that a 0 ends.
  - `execute`; 64 cells fit and the 65th overflows; `/mod` `/` `mod` (with the limits
    and division by zero), `um/mod` `um*`; vocabularies; `words` (184 names).
  - `ticks` and `ms`; the tick (500 in 1000 ms, a 40-cell stack survives 1000 ms of
    it, it runs after an error and after `reboot`).
  - `memit` and `mkey` through the D2-D3 wire (300 bytes round the ring, a 300-byte
    burst leaves 44, the 1000 ms timeout) and the vectors `>modem` `<modem`, put back
    by an error.
  - The source lines: `p` `list` `load`, one line changed with its page neighbours
    intact, 63 characters fit, 64 characters and lines 160 and -1 print `?` and write
    nothing, `n p` alone, line 0 after `reboot` and after a hardware reset, a bad line 0
    gives `?` and then the prompt, `wipe`. A jumper from D4 to 3V3 at reset skips
    line 0.
  - `fpage-erase` (any address in the page) and `fpage-prog`, and their refusals: a page
    that is not erased, an unaligned source, the source lines. `reboot`.
- Not checked on the board yet: the A7670E itself; whether the DMA keeps storing bytes
  while `fpage-prog` runs; `fpage-erase` / `fpage-prog` refusing the kernel and
  addresses beyond the flash (the emulator tests these; on the board a failure would
  erase the kernel).

## Open work

Steps 1 to 5a of the phone hardware are done (first flash, `ticks` and `ms`, the modem
UART, the I/O vectors, the tick interrupt); what they produced is described above. Steps
5b and 5c wait for the display and key hardware (on 2026-11-12 the owner expected it to
take more than a month).

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
- A device gets its own numbered file with its machine code and its words (`13-modem.s`,
  `14-display.s`, ...); pin and register equates go to `mcu.s`, into the section of their
  peripheral, and a new pin into the table above.
- Interrupts: at most **one**, and it must not nest. Its routine may use `ra`,
  `t0-t2`, `a0-a5` freely (the hardware prologue saves exactly those); to use `s0`, `s1`,
  `gp` or `tp` it must save them on the machine stack (`sp`) and restore them, within the
  12 cells `MSTACK_SIZE` leaves. The one interrupt is the tick, vector table entry 12;
  another would need the table extended to its number. HPE and the vector mode are set in
  CSRs described in `docs/ch32v006/QingKeV2_Processor_Manual.PDF` chapter 3.
- Everything that waits (for the modem, for a key) needs a timeout. A phone must not hang.

The steps:

5. **The tick's work** (the tick itself, 5a, exists): refresh one LED row
   (`docs/output/LED-matrix/Bitbang-LED-matrix.S` already keeps to the allowed registers),
   sample the 8 keys through the 74HC165, count time.
   - 5b, the LED row refresh in the tick (pins PC0, PC2, PA1, PA2; needs the matrix
     wired). Ask the owner how it is wired before writing code, and check it against the
     pin table.
   - 5c, the keys through the 74HC165 (shares CLK and OE, one more input pin; not tried).
6. **Key input**: chords are decoded on release (OR everything pressed since the first
   press, report it when all keys are up). Characters are entered with two strokes through
   a 64-byte table, `map[8 * first + second]`.
7. **Modes**: one vocabulary per mode (idle, dial, call, edit, ...), a variable that holds
   the current mode's vocabulary, and a handler that builds a name from the key mask
   (`k13` for keys 1 and 3) and looks it up with `find-name-in`, then in a common
   vocabulary. Do not switch CONTEXT from the key handler.
   **Errors must work without a console.** On the finished phone nothing is connected to
   USART1, so an error must not fall back to the console REPL. `reset` restarts the word
   held in a RAM cell instead: the REPL by default (developing, with a PC attached), or
   the phone's main loop, which puts itself there when it starts (from line 0, or from the
   lines it loads). That word sets the vectors it needs and shows the error, kept in RAM
   by the error path: the REPL on the console as now, the phone on the LED matrix (for
   example `?` and the word's name), cleared with a key. A trap still sends
   `T<mcause> <mepc>` to the console; on the phone it then resets the chip (later through
   the watchdog) instead of hanging. A restart word that fails at once would restart
   forever: a hardware reset clears the RAM cell, and PD4 skips the line 0 that sets it
   again. A REPL on the matrix and the 8 keys is possible later, but slow.
8. **Call log** in the user flash, 16-byte records (format in `etc/answers.md`).

Also open:
- A pyserial backend for `emulators/test_sixforths.py`, so the same tests run against the real
  board (and against the emulator through a fake port).
- Optional: `?do`.
