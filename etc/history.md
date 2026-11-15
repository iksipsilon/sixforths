# sixforths: how it got here

`CLAUDE.md` and the comments in the source describe the kernel as it is. This file keeps
what is no longer true or only tells the story: where the code came from, what the port
changed, and the dated reports of the steps that are done. No session needs to read it.

It was put together on 2026-11-15, when the history was taken out of `CLAUDE.md` and out
of the source comments. Commit `60edebb` has both as they were before.

## Where the kernel came from

sixforths began as a port of FiveForths (https://github.com/aw/FiveForths, MIT licence,
see `LICENSE`), an indirect-threaded Forth in RISC-V assembly for the GD32VF103 (Longan
Nano), to the WCH CH32V006F8U6 (RV32EC). Its working name was fotrh for a while; the test
file `emulators/test_fotrh.py` still carries it. The branch `kernel-phase1` was cut from
`extended-wordset`. `etc/flash-before-fable.bin` is the board's flash from before this
kernel.

Until 2026-11-15 every deliberate difference from FiveForths was marked in the source
with a `CH32V006 PORT:` or `CH32V006 PORT BUGFIX:` comment. This is what those comments
recorded.

Registers:
- RV32E has x0-x15 only, so the registers above x15 were remapped one to one: s2 -> tp
  (RSP), t3 -> a4, t4 -> a5, t5 -> gp. s3 and t6 were eliminated: return addresses go on
  the machine stack.
- On 2026-11-14 the data stack moved from sp to s0 (the QingKe V2 stores its interrupt
  frame at sp), and the variables moved above the machine stack, so that an overrun of
  that stack no longer overwrites STATE, TOIN, HERE and LATEST. FiveForths' unused NOOP
  cell went at the same time.
- NEXT's temporary became a5 instead of t0, which makes all four of its instructions
  2 bytes long (8 bytes instead of 10).
- PUSH moves the pointer first and stores after; the port introduced that order.

What the GD32V tolerated and the QingKe V2 does not:
- `number` compared the first two characters with one `lhu` against "0x". A token starts
  at any byte offset, and a misaligned halfword load traps here (mcause 4, seen on the
  board at exactly that instruction, depending on where in the line the token stood). It
  is two byte loads now.
- The two data words `.loop` / `.dloop` in the interpreter had no `.balign`. With
  compressed code before them they could land at an address 2 mod 4, and NEXT's `lw`
  trapped (seen on the board).
- `csrs mie, zero` in the interrupt setup was removed: the core has no mie / mip CSRs.
- The UART setup also set the RBNEIE / TCIE / TBEIE interrupt enables; they were dropped.
- The trap handler was a bare `mret`. It became the beacon that prints `T<mcause> <mepc>`.
  It was first aligned with `.balign 1024`, which cost about 1.6 KB of padding; the vector
  table at 0x0 made that unnecessary.
- The flash was linked at 0x08000000, as for the GD32V. The core runs from the 0x00000000
  alias, so `la sp, __stacktop` (auipc-based) computed 0x18002000 instead of 0x20002000.
  The link base is 0 now.
- One flash wait state at 24 MHz (without it the chip falls into a reset loop), and
  RCC_CFGR0 written wholesale (clearing HPRE alone left the console at half the baud rate
  on the board). The port's comment, and its first write-up, concluded from this that
  the V006 "resets with a /2 divider in some other CFGR0 field". It does not: on
  2026-11-15 CFGR0 was read on the board with the chip halted at reset, and it held 0x20,
  the manual's value (HPRE = SYSCLK / 3, every other field 0). The code that showed the
  half speed is not in the repository; a write that leaves HPRE at 0001 or 1000 would
  explain it, since both mean SYSCLK / 2.

The dictionary and the compiler:
- FiveForths hashed word names, and each `defcode` named the previous word's label. The
  headers are jonesforth's now (link, flags+length, name), chained by the macros.
- `:` pointed the code field at a `j docol` stub, one extra jump for every call of a
  colon word; it holds `docol` itself now.
- `execute` and `'` work with code field addresses instead of header addresses.
- `token` took the buffer address, and each of its six callers worked that out from TOIN
  and moved TOIN afterwards. `token` does both itself now.
- The `restorevars` macro ran only when a word was not found while compiling, and trusted
  that LATEST was the word being compiled. An error inside `[ ... ]`, a full dictionary
  or an oversized token left a hidden header and its cells behind, and a typo after a
  stray `]` removed the last finished word (or, with no RAM word yet, pointed HERE into
  flash). `abandon_def`, driven by the hidden flag, replaced it.
- `;` unhid the word before it checked for room, so a `;` that found the dictionary full
  left an unfinished word defined; and the interpreter compiled into a definition with no
  bounds check at all (both fixed in `b13ad53`).
- `c,` and `allot` could leave HERE unaligned, and the error path's zero-fill then
  trapped: any error typed after `3 allot` hung the board in the trap handler.
- Message lengths were counted by hand at each use; the `message` macro marks the end
  with a label.
- The REPL did not echo the newline, stored DEL in the TIB as a token byte, and let ANSI
  escape sequences through.

The files:
- `src/mcu.s` was a rewrite of FiveForths' `src/mcus/gd32vf103/mcu.s`; the separate board
  file (`board.s`), whose only line was the RAM size, went into it.
- `08-primitives.s` merged FiveForths' `08-forth-primitives.s` with the eForth-style and
  ANS-style words the port added.
- `prelude.f` held 57 Forth words that were typed (or loaded from flash) into RAM at every
  boot, where they took about 2.8 KB of the 6.9 KB dictionary. They became the
  hand-written threads of `10-forth-words.s`.
- The Makefile and `number` carried a shift-add fallback for `mul`, for binutils older
  than 2.39 (no Zmmul). It was stale once `*` and `um*` used `mul` too, and went in the
  cleanup of 2026-11-15.
- A source-replay log in flash (`+log`, `-log`, `log_commit`, `log_scan`) recorded typed
  lines and replayed them at boot. On 2026-11-14 the 160 numbered source lines replaced
  it: the owner found the appending log too complex, and nothing is saved automatically
  any more. `etc/source-lines.md` compares the two.

The port's first write-up was `old-docs/CH32V006.md`. It was removed on 2026-11-15
together with FiveForths' own manuals in `old-docs/` and FiveForths' `README.md`; git has
them all (`git show 7b119e8:old-docs/CH32V006.md`). Beyond what is listed above, it
records:
- The first register mapping was s2 -> s0 (RSP), t3 -> a4, t4 -> a5, t5 -> gp, t6 -> tp,
  with s3 eliminated by spilling ra to the return stack. That made the return stack
  pointer something that had to be set before the boot banner.
- The QingKe V2 masks the low bits of the trap vector base. Before the handler was 1 KiB
  aligned, every trap went to 0x000 = `_start` and looked like a spontaneous reboot.
- The port began with FiveForths' 19 primitives and 26 new ones in
  `src/11-eforth-primitives.s` (`um+` among them), and deleted `djb2.c` and the
  `make djb2` target along with the hashed headers.
- A pull request to FiveForths was considered: the branch was clean onto its master
  `d6432a1`, with the jonesforth headers as the divergence to discuss.

## The cleanup of 2026-11-15

- The port comments in `src/`, `sixforths.s`, the Makefile and `linker.ld` were rewritten
  to say what the code does. The FiveForths banner in `sixforths.s` became one line, and
  `LICENSE` got the MIT text.
- Unused names went: `FORTH_VERSION`, and the labels `uart_done`, `gpio_done`,
  `execute_done`, `compile_done`, `interpreter_tib`.
- Renames: `12-flash.s`, `13-ticks.s`, `14-modem.s` became `11-`, `12-`, `13-` (there was
  no `11-*.s`); `03-interrupts.s` became `03-traps.s`, and `interrupt_handler` /
  `interrupt_init` became `trap_handler` / `trap_init`; the console's `UART_BASE_ADDRESS`,
  `UART_RX_STATUS`, `UART_TX_STATUS`, `UART_RX_DATA`, `UART_TX_DATA`, `UART_RX_BIT`,
  `UART_TX_BIT` gave way to the reference manual's names the modem already used; the TIB
  got its own `TIB_SIZE`; the constants in `mcu.s` were regrouped by peripheral. None of
  this changed a byte of the kernel (13,580 bytes, the same checksum throughout).
- Five kernel changes followed, each with the tests run, which brought it to 13,556 bytes:
  `reset` no longer clears a0-a3; the jump in front of `execute` went; a line may not
  fill the TIB's last byte (a 255-character line used to make `token` read past the TIB);
  backspace clears the erased character in the TIB (two erasures and Enter used to end in
  `?`); `reset` no longer loads s1.

## From the old CLAUDE.md, word for word

The three parts below are the text of `CLAUDE.md` as it stood on 2026-11-15 before it
was rewritten (file names as after the renames of that day).

### Done in `kernel-phase1`

Done in `kernel-phase1` (all tested in the emulator; flashed on 2026-11-12, and the Phase 2
step 1 checks passed on the board): HERE alignment, interrupt-safe PUSH, the merged
primitives file, the prelude in flash, `s=` `scan` `/string`, the user flash page words,
error recovery by the hidden flag, vocabularies. `fpage-erase` ran on the board in the step 3
experiment; `fpage-prog` has not run there yet.

### Where we stopped (2026-11-12 to 2026-11-14)

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


### Phase 2, steps 1 to 5a, as they were reported

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
