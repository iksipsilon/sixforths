# Answers to `etc/qustions-suggstions.txt`

Written 2026-11-12 for the branch `kernel-phase1`. Each section says what was decided,
why, and whether it is already in the kernel or still a plan. Everything marked *done*
passes in the emulator (`emulators/test_fotrh.py`, 160 tests) and has **not yet run on
the board**. Things nobody has checked are collected at the end.

## 1. Registers

**Decision (done): the assignment stays, and registers keep their ABI names.**

| Forth register | Register | How to remember |
|---|---|---|
| DSP, data stack pointer | `sp` | the three registers that start with "s" ... |
| RSP, return stack pointer | `s0` | ... are the three Forth pointers |
| IP, instruction pointer | `s1` | |
| W, word pointer | `a0` | first argument register: NEXT hands W to the code-field routine |

`sp`, `s0`, `s1` are also the registers that no subroutine and no interrupt touches.

Why not `RSP = ra`, `IP = gp`, `W = tp`:
- `ra` is overwritten by every `call`. The kernel calls subroutines everywhere (`token`,
  `lookup`, `uart_put`, ...). Using `ra` for RSP would mean giving up `call` / `ret`.
- `gp` and `tp` work, but cost flash: the 2-byte forms of `lw` / `sw` through a pointer
  only take `s0`, `s1`, `a0`-`a5`. Measured size of NEXT: 12 bytes with `gp` / `tp`,
  10 bytes as it was, 8 bytes now (its temporary moved from `t0` to `a5`).

Why no aliases (`#define RSP s0`): the assembler has no register alias for RISC-V
(`.equ RSP, s0` fails with "illegal operands"), so it would need the C preprocessor in
the build. With the "three s registers" rule there is nothing left to rename. The names
`X0`-`X8` would also collide with `x0`-`x8`, the real names of zero, ra, sp, gp, tp, t0,
t1, t2, s0.

Scratch registers:
- `t0`-`t2`, `a1`-`a5`, `gp`, `tp` are free inside a primitive. Prefer `a1`-`a5` in new
  code (shorter instructions). Existing primitives were not rewritten for this.
- `t0` is the temporary of PUSH, PUSHRSP, POPRSP and checkunderflow. POP does not use it.
- NEXT uses `a5`.
- `ra` belongs to `call` / `ret`.

**The `sp` problem (done).** The QingKe V2 saves ten registers into 48 bytes at `sp` when
an interrupt arrives (processor manual 3.4), and `sp` is the data stack. PUSH used to
store at `-4(sp)` and then move `sp`, so an interrupt between the two instructions would
have overwritten the new cell. PUSH and PUSHRSP now move the pointer first (this is also
2 bytes shorter each time). 48 bytes (`IRQ_FRAME`) stay free under the data stack, so it
holds 52 cells. Swapping registers would not have helped: whichever stack sits on `sp`
gets the frame.

**Interrupt rule.** An interrupt routine may use only `ra`, `t0`-`t2`, `a0`-`a5`: those
are what the hardware saves and restores. It must leave `sp`, `s0`, `s1`, `gp`, `tp`
alone. That is why `gp` and `tp` not being saved is no problem.

## 2. Flash and RAM

RAM is the scarce resource, not flash.

| Flash | Size | Use |
|---|---|---|
| 0x0000-0x3FFF | 16 KiB | kernel (13,596 bytes used, 2026-11-12) |
| 0x4000-0x67FF | 10 KiB | source-replay log |
| 0x6800-0xF7FF | 36 KiB | user flash: application data |

- The phonebook and the SMS stay on the SIM for now, so the 36 KiB are free. They may
  move to the user flash or the SD card later, depending on how much the SIM holds
  (section 9).
- RAM dictionary: 6,856 bytes, **empty after boot** now that the prelude lives in flash
  (it used to take about 2.8 KiB at every boot). Buffers for the modem line, the SMS
  editor and two SD sectors will take roughly 1.5 KiB of it (estimate).
- Glyph table for the 3x5 font: 15 bits per glyph, so one halfword each; 95 ASCII glyphs
  are 190 bytes of kernel `.rodata`. No flash region needed. *(plan)*
- The key-to-AT-command code is ordinary kernel code. *(plan)*

**User flash words (done):** `fpage-erase ( page -- )` and `fpage-prog ( src page -- )`
work on one 256-byte page and refuse every address outside 0x08006800-0x0800F7FF.

### Call log *(plan)*

Kept by the MCU, not by the modem. `AT+CPBS` knows the lists "DC", "MC" and "RC"
(dialled, missed, received), but an entry holds only index, number, type and name: no
time and no duration, and three separate lists cannot be shown as one history.

Top 4 KiB of flash (0x0800E800-0x0800F7FF), a ring of 16-byte records: 16 per page,
256 calls.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | time, packed 6:4:5:5:6:6 bits = year, month, day, hour, minute, second (`AT+CCLK?`) |
| 4 | 2 | duration in seconds |
| 6 | 1 | flags: bit 0 = outgoing, bit 1 = answered |
| 7 | 1 | number of digits; bit 7 = leading `+` |
| 8 | 8 | number as BCD, right-aligned, padded with F on the left |

An erased record reads 0xFF everywhere. The three filters are one loop over the records
with a different test:
1. all calls: no test;
2. one contact or number: compare the last cell of the record (the last 8 digits) with
   the last 8 digits of the number. `+385 9x ...` and `09x ...` then match;
3. missed: incoming and not answered.

Appending rewrites one page, like `log_commit` does. A page erase takes 3 ms and the
datasheet promises at least 100,000 cycles, so wear is not a concern.

### SMS of one contact in one place *(plan)*

No header is needed while the messages are on the SIM. Send with `AT+CMGW` followed by
`AT+CMSS`, so a sent message stays in the storage; one `AT+CMGL="ALL"` pass filtered by
number then shows both directions. A stored outgoing message has no time stamp, so the
order follows the storage slots. If an SD card is added later, the call record above
also works as a message header.

## 3. The prelude in flash

**Done.** "Freezing" never meant rewriting colon words as machine code. It means the same
threads, moved from RAM to flash and written in assembly source as `defword` plus `.int`
lists (`src/10-forth-words.s`, 39 words). Words that are shorter in machine code moved to
`src/08-primitives.s` instead.

The rule: byte loops and stack shuffling go to machine code, words that mostly call
other words stay threads. `type` is 64 bytes as a thread and 32 bytes as machine code;
`.` is 11 cells that are all calls.

Things to know when adding a word to flash:
- A variable cannot live in flash. It needs a RAM cell `var_X` and a `defcode` that
  pushes its address (`base`, `hld`).
- Branch targets are absolute addresses; local labels (`1:` ... `1b`, `2f`) do it.
- The comment above each thread is its Forth source. `emulators/check_threads.py` types
  that comment into the kernel's own compiler and compares the result with the thread,
  so a hand-translation mistake is caught.

The primitives are now one file, `08-primitives.s`, sorted by function: inner
interpreter, data stack, return stack, memory, arithmetic, logic, comparison, strings
and parsing, compiler and dictionary, vocabularies, input and output, system. The
dictionary is searched from the end of the last file backwards.

`prelude.f` is empty and stays as the place for words under development.

## 4. Vocabularies or xt tables

**Decision: both, each for what it is good at.** Fig-Forth style vocabularies for the
command bindings *(kernel part done)*, a plain table for the character map *(plan)*.

| | xt table per mode | vocabulary per mode |
|---|---|---|
| Kernel changes | none | search and definition must know the vocabulary |
| Dispatch | one indexed fetch | name search, tens of microseconds |
| Key chords (255 combinations) | 256 cells per mode, or a searched list | define only the ones that exist |
| Keys that work everywhere | copied into every table | found by falling through to the common words |
| Reading the code | positions in a list | `edit words` lists the bindings |
| Testing | by index | type the key names at the console |
| In flash | trivial | the head cell must be in RAM |

In the kernel now:

    vocabulary edit                    make one
    edit definitions : k3 ... ;        add words to it
    forth definitions                  back to the main vocabulary
    edit k3 forth                      edit is searched first, FORTH second

- Search order is CONTEXT, then FORTH. No F83 search-order stack, no hashed threads.
- `find-name-in ( addr len voc -- header | 0 )` searches one vocabulary only.
- `forget` trims every vocabulary and removes vocabularies defined after the word.
- Any error puts CONTEXT and CURRENT back to FORTH.

Plan for the phone:
- One vocabulary per mode (idle, dial, call, edit, ...).
- **The UI mode is a variable of its own, not CONTEXT.** CONTEXT also decides what the
  console and the log replay find; a `RING` that switched it would change what a typed
  line means.
- The key handler builds a name from the key mask (`k13` for keys 1 and 3), looks it up
  in the mode's vocabulary with `find-name-in`, then in a common one.
- The character map of the editor is data, so it is a table.

## 5. Key input *(plan)*

- Decode chords when the keys are released: OR together everything pressed since the
  first press, report it when all keys are up. Otherwise "index + middle" arrives as 1,
  then 2. The price: no auto-repeat.
- Enter characters with two strokes (group, then pick), not by pressing a key several
  times: no timeout, and every character costs exactly two presses.
- 5 keys give 5 x 5 = 25 characters, one letter short. 8 keys give 64: a-z, 0-9, space
  and punctuation from one 64-byte table, `map[8 * first + second]`.
- 8 candidates at 4 pixels each are 32 columns: on the 5x32 display each candidate
  stands above its key.
- Soroban digits (thumb = 5, fingers = 1 each) still work as chords on 5 of the 8 keys.
- 74HC165: it can share CLK with the MBI5024 chain and take its PL input from OE (high
  while a row is shifted out, low in between), leaving one new input pin for Q7. The
  keys are then read during the first 8 clocks of every row refresh. **Not tried.** The
  datasheet has a note on the level of CP when PL rises, and CLK idles low here.

## 6. Primitives

The kernel has 182 words (2026-11-12): 143 in machine code, 39 as threads.

Changed in this branch:
- 15 prelude words became machine code, among them `type count space cr c, align move
  depth 0> u/mod /mod / mod [ ]`.
- New: `s=`, `scan`, `/string` (for reading modem answers), `fpage-erase`, `fpage-prog`,
  the vocabulary words, `>body`.
- Dropped: `nand`, `um+` (nothing used them).
- `forget` is machine code now.

Added since, with their drivers (phase 2 in `CLAUDE.md`): `ticks` `ms` `irqs`, the modem
words `mkey?` `mkey` `memit` `mtimeout`, and the I/O vectors `>console` `>modem`
`<console` `<modem`. Still to add: the display and key words.

Names follow the Forth-2012 glossary where a word exists there. Full compliance is not a
goal.

## 7. Interrupts and DMA *(plan)*

One of each and no more:
- **Modem receive through DMA into a ring buffer in RAM.** No interrupt routine; the main
  loop polls the buffer. A receive interrupt would not survive a flash write: its routine
  is in flash, and flash is busy for about 3 ms (35 bytes at 115200 baud).
- **One tick interrupt, about every 2 ms:** refresh one LED row, sample the keys, count
  time. Without it every waiting loop would have to refresh the display itself.

## 8. Faults found while reading, fixed in this branch

- An error while HERE was odd (after `c,` or `3 allot`) trapped in `ram_init` instead of
  printing `?`. `,`, `:`, `create` and the error path now round HERE up.
- After an error the kernel removed the newest word even if it was finished (for example
  `] nosuchword`). It now removes a word only if it is still hidden, which is true
  exactly while it is being compiled.
- Colon words made at run time went through an extra jump (`.addr: j docol`). They point
  at `docol` now.

## 9. Not checked by anyone yet

- The whole branch on the real chip: phase 2 steps 1 to 5a passed there on 2026-11-12
  (`CLAUDE.md`); `fpage-prog` and the log-full path have not run there yet.
- ~~Whether the DMA keeps storing bytes while a flash page is erased.~~ It does (checked
  2026-11-12 with USART1 and DMA channel 5, see phase 2 step 3 in `CLAUDE.md`), so the
  call log may be written while the modem talks. Page programming was not tried.
- Whether the A7670E has the "DC" / "MC" / "RC" lists (`AT+CPBS=?` shows it). The plan
  does not depend on them.
- How much the SIM holds. `AT+CPBS?` gives the phonebook's used and total entries,
  `AT+CPBR=?` the entry numbers and the longest number and name, `AT+CPMS?` the SMS slots
  (`AT+CPMS=?` lists the storages the modem offers). It decides whether the phonebook and
  the SMS stay on the SIM (section 2).
- The 74HC165 wiring idea in section 5.
- The RAM estimate for the phone's buffers in section 2.

## Sources

- 3GPP TS 27.007, `+CPBS`: https://itecspec.com/spec/3gpp-27-007-8-11-select-phonebook-memory-storage-cpbs
- Missed-calls list read with `AT+CPBR` (Quectel forum): https://forums.quectel.com/t/is-it-possible-to-delete-the-missed-calls-list/44023
- A76XX Series AT Command Manual V1.09 (`AT+CMGW`, `AT+CMSS`): https://mt-system.ru/upload/iblock/1f1/yd57kuf244lsthmnqyhnxkmmonsjqtkz.pdf
- In `docs/`: QingKe V2 processor manual 3.4 (interrupt frame), CH32V006 datasheet section 3.3
  (flash erase time, table 3-15 endurance), 74HC165 datasheet.
