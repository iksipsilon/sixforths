#!/usr/bin/env python3
"""Tests for the kernel words (and prelude.f, if it holds any), run in the RV32EC emulator."""
import os, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import harness as h

failures = 0

def check(name, e, out, expect, absent=()):
    """expect: list of substrings that must appear in out (echo included)."""
    global failures
    problems = []
    if e.fault is not None:
        problems.append(f"fault={e.fault}")
    for s in expect:
        if s not in out:
            problems.append(f"missing {s!r}")
    for s in absent:
        if s in out:
            problems.append(f"unexpected {s!r}")
    if problems:
        failures += 1
        print(f"FAIL {name}: {'; '.join(problems)}")
        print(f"   out: {out[-260:]!r}")
        print(f"   pc trace: {[hex(p) for p in e.trace[-8:]]}")
    else:
        print(f"PASS {name}")

t0 = time.time()
B0 = h.boot()
print("boot banner ok:", "sixforths v0.0" in bytes(B0.uart_out).decode("latin1"), "fault:", B0.fault)

# ---- load the prelude line by line, flag any '?' ----
lines = [l for l in open(os.path.join(HERE, "..", "prelude.f")).read().split("\n")]
B = B0
import copy
E = copy.deepcopy(B0)
bad = []
for ln in lines:
    if not ln.strip():
        continue
    out, steps = h.feed(E, ln + "\n")
    if E.fault is not None or steps < 0:
        bad.append((ln, E.fault, steps, out[-120:]))
        break
    # an error prints "  ?..." on its own line after the echoed input (line 0;
    # a comment line has no echoed newline, so nothing follows it)
    if any(r.lstrip().startswith("?") for r in out.split("\n")[1:]):
        bad.append((ln, None, steps, out[-120:]))
if bad:
    print("PRELUDE LOAD FAILED:")
    for b in bad: print("  ", b)
    sys.exit(1)
print(f"prelude loaded in {time.time()-t0:.1f}s; HERE-RAM_BASE = {h.ram_word(E, 0x20001CF4) - 0x20000000} bytes of dictionary")

P = E  # prelude-loaded machine

def t(name, src, *expect, absent=("  ?",)):
    e, out, steps = h.session(P, src + "\n")
    check(name, e, out, list(expect), absent)
    return out

# ---- kernel primitives, via the prelude's number output ----
t("emit (no leading space)", "65 emit", "65 emit\nA", absent=("65 emit\n A",))
t("mul", "6 7 * .", "42 ")
t("mul negative", "-6 7 * .", "-42 ")
t("um* 10^6 * 10^6", "1000000 1000000 um* u. u.", "232 3567587328 ")
t("um* max * 1", "0xFFFFFFFF 1 um* u. u.", "0 4294967295 ")
t("um* max * max", "0xFFFFFFFF 0xFFFFFFFF um* u. u.", "4294967294 1 ")
t("um* mid carry", "0x10001 0x10001 um* u. u.", "1 131073 ")
t("um/mod 64-bit", "1 2 3 um/mod u. u.", "2863311531 0 ")
t("um/mod big divisor", "0 1 0x80000001 um/mod u. u.", "1 2147483647 ")
t("u/mod", "100 7 u/mod u. u.", "14 2 ")
t("/mod -7 2", "-7 2 /mod . .", "-3 -1 ")
t("/mod 7 -2", "7 -2 /mod . .", "-3 1 ")
t("/ and mod", "100 7 / . 100 7 mod .", "14 2 ")
t("shifts", "1 31 lshift u. 0x80000000 31 rshift . -8 2/ . 5 2* .", "2147483648 1 -4 10 ")
t("1+ 1- cells cell+", "5 1+ . 5 1- . 3 cells . 8 cell+ .", "6 4 12 12 ")
t("negate abs", "5 negate . -5 abs . 5 abs .", "-5 5 5 ")
t("min max", "3 9 min . 3 9 max . -3 3 min .", "3 9 -3 ")
t("compare signed", "3 5 < . 5 3 < . -1 1 < . 5 3 > .", "-1 0 -1 -1 ")
t("compare unsigned", "-1 1 u< . 1 -1 u< . 5 3 u> .", "0 -1 -1 ")
t("equality", "3 3 = . 3 4 = . 3 4 <> . 3 3 <> .", "-1 0 -1 0 ")
t("0>", "5 0> . 0 0> . -5 0> .", "-1 0 0 ")
t("stack ops", "1 2 3 rot . . . 1 2 nip . 1 2 2dup . . . . 1 2 2drop depth .", "1 3 2 2 2 1 2 1 0 ")
t("?dup", "5 ?dup . . 0 ?dup .", "5 5 0 ")
t("+!", "variable v 5 v ! 3 v +! v @ .", "8 ")
t("depth and .s", "1 2 3 depth . .s", "3 1 2 3 ")

# 50 loop results plus the two loop parameters of the second loop = 52 cells
t("52 cells fit on the data stack", ": f52 50 0 do i loop 50 0 do drop loop 65 emit ; f52", "f52\nA")
t("the 53rd overflows", ": f53 51 0 do i loop 51 0 do drop loop 65 emit ; f53", "? stack overflow", absent=("f53\nA",))
t("sp@", "7 sp@ @ .", "7 ")

# ---- memory ----
t("cmove fill", "65 pad c! 66 pad 1+ c! pad pad 8 + 2 cmove pad 8 + c@ . pad 9 + c@ . pad 4 88 fill pad 3 + c@ .", "65 66 88 ")
t("move overlap (dst>src)", "65 pad c! 66 pad 1+ c! 67 pad 2 + c! pad pad 1+ 3 move pad 1+ c@ . pad 3 + c@ .", "65 67 ")
t("move overlap (dst<src)", "65 pad 1+ c! 66 pad 2 + c! 67 pad 3 + c! pad 1+ pad 3 move pad c@ . pad 2 + c@ .", "65 67 ")
t("align allot c,", "here @ 3 allot align here @ swap - . here @ 65 c, 66 c, dup c@ . 1+ c@ .", "4 65 66 ")

t("error with HERE unaligned", "3 allot nosuchword\n65 emit", "  ?", "65 emit\nA", absent=())
t(": after an odd allot", "1 allot : aa 7 ; aa .", "7 ")
t("create after c,", "65 c, create zz 9 , zz @ .", "9 ")
t(", after c,", "65 c, here @ 3 + -4 and 77 , @ .", "77 ")

# ---- control flow ----
t("begin until", ": c5 5 begin dup . 1- dup 0= until drop ; c5", "5 4 3 2 1 ")
t("while repeat", ": w3 0 begin dup 3 < while dup . 1+ repeat drop ; w3", "0 1 2 ")
t("if else then", ": sg dup 0< if drop 45 emit else drop 43 emit then ; 5 sg -5 sg", "+-")
t("again + exit", ": ag 0 begin 1+ dup 3 = if exit then again ; ag .", "3 ")
t("do loop", ": d5 5 0 do i . loop ; d5", "0 1 2 3 4 ")
t("+loop up", ": d10 10 0 do i . 3 +loop ; d10", "0 3 6 9 ")
t("+loop down", ": dn 0 10 do i . -3 +loop ; dn", "10 7 4 1 ")
t("loop negative range", ": dneg -2 -4 do i . loop ; dneg", "-4 -3 ")
t("loop j", ": dj 3 0 do 2 0 do j . i . loop loop ; dj", "0 0 0 1 1 0 1 1 2 0 2 1 ")
t("unloop exit", ": ul 10 0 do i 3 = if unloop exit then i . loop ; ul", "0 1 2 ")
t("recurse", ": fact dup 1 > if dup 1- recurse * then ; 5 fact .", "120 ")
t("[ ] literal", ": ten [ 5 5 + ] literal ; ten .", "10 ")

# ---- errors inside a definition: it is dropped, nothing else is ----
def here_after(src):
    e, out, _ = h.session(P, "here @ .\n" + src + "\nhere @ .\n")
    nums = [l.split()[0] for l in out.split("\n") if l.strip().endswith("ok") and l.split()[0].isdigit()]
    return e, out, nums
for name, src in (("an unknown word", ": bad 1 2 nosuchword"), ("an error between [ and ]", ": bad 1 [ 5 nosuchword"),
                  ("an oversized token", ": bad 1 " + "x" * 40), ("stack underflow in [ ]", ": bad [ drop")):
    e, out, nums = here_after(src)
    check(f"definition dropped after {name}", e, out + f" same={len(nums) == 2 and nums[0] == nums[1]}", ["  ?", "same=True"], absent=())
    e, out, _ = h.session(P, src + "\nbad\n")
    check(f"... and its name is gone ({name})", e, out + f" errors={out.count('  ?')}", ["errors=2"], absent=())
t("a stray ] and a typo leave the last word alone", ": keep 5 ; ] nosuchword\nkeep .", "  ?", "keep .\n5 ", absent=())
e, out, _ = h.session(B0, "] nosuchword\n: sq dup * ; 7 sq 16 + emit\n")
check("... also when no RAM word exists yet", e, out, ["emit\nA"], absent=())

# ---- defining words ----
t("variable", "variable x 7 x ! x @ .", "7 ")
t("constant", "100 constant hundred hundred .", "100 ")
t("bl", "bl .", "32 ")
t("create", "create foo 5 , foo @ .", "5 ")
t("does> (constant-like)", ": c2 create , does> @ ; 42 c2 answer answer .", "42 ")
t("does> (array)", ": arr create cells allot does> swap cells + ; 5 arr a5 99 2 a5 ! 2 a5 @ .", "99 ")
t("does> keeps old words", ": c2 create , does> @ ; 1 c2 one 2 c2 two one . two .", "1 2 ")

# ---- strings and parsing ----
t('." ', ': g ." hello" ; g', "hello")
t('s" type', ': g2 s" abc" type ; g2', "abc")
t('." alignment', ': g3 ." a" ." bcdef" 33 emit ; g3', "abcdef!")
t("count", "create cs 3 c, 65 c, 66 c, 67 c, cs count type", "ABC")
t("s\" keeps inner spaces", ': g5 s" a b  c" type ; g5', "a b  c")
t('empty ."', ': g6 ." " 65 emit ; g6', "A")
t("+loop overshoot", ": ov 3 0 do i . 2 +loop ; ov", "0 2 ")
t("um/mod by zero does not trap", "5 0 0 um/mod u. u.", "4294967295 5 ")
t("forget refuses flash words", "forget dup 65 emit", "  ?", absent=("A",))
t("parse-name", ": pn parse-name type ; pn hello", "hello")
t("number ok", ': nn s" 123" number . . ; nn', "0 123 ")
t("number bad", ': nb s" 12x" number nip 0= . ; nb', "0 ")

t("s= equal", ': q1 s" RING" drop s" RING" s= . ; q1', "-1 ")
t("s= on a prefix", ': q2 s" RINGO" drop s" RING" s= . ; q2', "-1 ")
t("s= differs in the last byte", ': q3 s" RINK" drop s" RING" s= . ; q3', "0 ")
t("s= of nothing", "pad pad 1+ 0 s= .", "-1 ")
t("scan finds", ': q4 s" ab,cd" 44 scan type ; q4', ",cd")
t("scan misses", ': q5 s" abc" 44 scan . drop ; q5', "0 ")
t("/string", ': q6 s" hello" 2 /string type ; q6', "llo")
t("a field of a modem line", ': q7 s" +CLIP: 123,145" 32 scan 1 /string 2dup 44 scan nip - type ; q7', "q7\n123")

# ---- tick, execute, find ----
t("[']", ": tt ['] dup ; 5 tt execute . .", "5 5 ")
t("' execute", "' words execute", " words ")
t("find", 'create nm 3 c, 100 c, 117 c, 112 c, nm find . drop', "-1 ")
t("find miss", 'create nm 3 c, 122 c, 122 c, 122 c, nm find . drop', "0 ")
t("forget", ": ff1 1 ; : ff2 2 ; forget ff2 ff1 . ff2", "1 ", absent=())

# ---- vocabularies ----
VOC = "vocabulary edit\nedit definitions : k3 70 emit ; forth definitions\n: k3 71 emit ;\n"
t("the same name in two vocabularies", VOC + "k3\nedit k3 forth\nk3", "\nk3\nG", "edit k3 forth\nF", absent=("  ?",))
t("a miss falls through to FORTH", VOC + "edit 65 emit forth", "forth\nA")
out = t("words lists the context vocabulary only", "vocabulary edit edit definitions : k3 ; : k4 ; forth definitions\nedit words forth", "forth\n k4 k3   ok")
t("find-name-in", VOC + "' edit >body constant ev\n: t1 s\" k3\" ev find-name-in >cfa execute ; t1\n: t2 s\" dup\" ev find-name-in . ; t2",
  "t1\nF", "t2\n0 ")
t("find-name follows the search order", VOC + ': t3 s" k4" find-name 0= . ; edit definitions : k4 ; forth definitions\nt3 edit t3 forth', "-1 0 ")
t("an error goes back to FORTH", "vocabulary edit edit definitions\nnosuchword\n: q5 5 ; q5 . edit q5", "5 ", absent=())
out = t("... and the new word went to FORTH", "vocabulary edit edit definitions\nnosuchword\n: q5 5 ;\nedit words", "words\n   ok", absent=())
t("an error with an empty vocabulary current", "vocabulary e2 e2 definitions nosuchword\n65 emit", "  ?", "emit\nA", absent=())
t("a failed definition in a vocabulary is dropped", "vocabulary edit edit definitions : ok1 1 ; : bad 2 nosuchword\nedit ok1 . bad", "ok1 . bad\n1   ?", absent=())
t("recurse in a vocabulary", "vocabulary edit edit definitions : fact dup 1 > if dup 1- recurse * then ; forth definitions edit 5 fact . forth", "120 ")
t("defining words in a vocabulary", "vocabulary edit edit definitions 42 constant kk variable vv 7 vv ! : im 65 emit ; immediate forth definitions\nedit kk . vv @ . : x im ; forth",
  "42 7 A")
t("latest in FORTH", "latest @ 4 + c@ 31 and . : zz ; latest @ 4 + c@ 31 and .", "2 ")
FG = ("vocabulary edit\n: a1 1 ;\nedit definitions : k4 4 ; forth definitions\n: b1 2 ;\n"
      "edit definitions : k5 5 ; forth definitions\nedit forget k4 forth\n")
t("forget trims every vocabulary", FG + "a1 . edit a1 . forth : c1 3 ; c1 .", "1 1 3 ")
for w in ("b1", "edit k4", "edit k5"):
    t(f"... {w} is gone", FG + w + " 66 emit", "  ?", absent=("B",))
e, out, _ = h.session(P, "here @ .\n" + FG + "here @ .\n")
nums = [l.split()[0] for l in out.split("\n") if l.strip().endswith("ok") and l.split()[0].isdigit()]
check("... and HERE is back at k4", e, f"{int(nums[1]) - int(nums[0])}", ["52"])   # edit (28 bytes) + a1 (24 bytes) remain
FV = "vocabulary v2\nv2 definitions : x1 1 ;\nforget v2\n"
t("forget a vocabulary while it is current", FV + ": y1 7 ; y1 . voc-link @ . words", "7 0 ", " y1 ", " dup ")
t("... its name is gone", FV + "v2", "  ?", absent=())
t("forget keeps older vocabularies", "vocabulary v1 v1 definitions : p1 11 ; forth definitions vocabulary v2\nforget v2\nv1 p1 . forth voc-link @ ' v1 >body 4 + = .", "11 -1 ")
t("... but not what was added to them later", "vocabulary v1 vocabulary v2 v1 definitions : p1 11 ; forth definitions\nforget v2\nv1 p1", "  ?", absent=())
t("forget refuses a word of an unselected vocabulary", VOC + "vocabulary e3 e3 definitions : only 1 ; forth definitions\nforget only", "  ?", absent=())
# vocabularies survive the source log
e = copy.deepcopy(B0)
h.feed(e, "+log\n" + VOC)
r = h.boot(flash=bytes(e.f))
out, _ = h.feed(r, "k3 edit k3 forth k3\n")
check("vocabularies come back with the log", r, out, ["forth k3\nGFG"])

# ---- numbers and debugging ----
t("print limits", "2147483647 . -2147483648 . 0 .", "2147483647 -2147483648 0 ")
t("hex", "hex 255 u. -1 u. decimal 255 .", "FF FFFFFFFF 255 ")
t("dump", "pad 4 65 fill pad 4 dump", "41 41 41 41 ")

t("spaces", "65 emit 3 spaces 66 emit 0 spaces 67 emit -2 spaces 68 emit", "A   BCD")
t("u. and base", "hex 4096 u. decimal 4096 u. base @ .", "1000 4096 10 ")
t("hold sign in a picture", ": pic dup abs 0 <# # # 46 hold #s rot sign #> type ; -1234 pic", "-12.34")
t("cr", "65 emit cr 66 emit", "A\r\nB")
t("type of nothing", "pad 0 type 65 emit", "emit\nA")
t("/ and mod signed", "-7 2 / . -7 2 mod . 7 -2 / . 7 -2 mod . -7 -2 / . -7 -2 mod .", "-3 -1 -3 1 3 -1 ")
t("/mod limits", "-2147483648 1 /mod . . 2147483647 -1 /mod . .", "-2147483648 0 -2147483647 0 ")
t("division by zero does not trap", "7 0 /mod 2drop 7 0 / drop 7 0 mod drop 7 0 u/mod 2drop 65 emit", "emit\nA")
t("depth of an empty stack", "depth .", "0 ")
t("nested literal string words", ': g7 s" ab" s" cd" type type ; g7', "cdab")

# ---- abort, quit ----
t("abort", "5 abort 66 emit", "  ?", absent=("B",))
e, out, _ = h.session(P, "1 2 : q quit ; q 65 emit\n66 emit\n. .\n")
check("quit (drops rest of line, keeps stack)", e, out, ["B", "2 1 "], absent=("A",))

# ---- key? ----
e, out, _ = h.session(P, "key? .\n")
check("key? empty", e, out, ["0 "])
e, out, _ = h.session(P, "key? .\n65 emit\n")
check("key? pending", e, out, ["-1 ", "A"])

# ---- vector table at 0x0: reset -> boot, exceptions -> entry 3 -> beacon ----
check("mtvec = 3 after boot", B0, f"mtvec={B0.csr.get(0x305)};", ["mtvec=3;"])
FLASH = open(h.BIN, "rb").read()
vec = lambda n: int.from_bytes(FLASH[4 * n:4 * n + 4], "little")
hdl = h.SYM["interrupt_handler"]
check("vectors 2 and 3 point to the handler", B0,
      f"nmi={vec(2):#x} exc={vec(3):#x}", [f"nmi={hdl:#x}", f"exc={hdl:#x}"])
# regression: on silicon mcause is not 0 after reset (the board read 0x800000D9)
e = h.Emu(FLASH, b"")
e.csr[0x342] = 0x800000D9
h.run_idle(e, 100_000)                    # boot needs ~8,200 steps
check("reset boots even with mcause != 0", e, bytes(e.uart_out).decode("latin1"), ["sixforths v0.0"])
e = copy.deepcopy(B0)
e.csr[0x342], e.csr[0x341], e.pc = 4, 0x1234, vec(3)   # hardware: misaligned load at 0x1234
start = len(e.uart_out)
try:
    for _ in range(20000):
        if e.pc == h.SYM["beacon_hang"]:
            break
        e.step()
except RuntimeError:
    pass
out = bytes(e.uart_out[start:]).decode("latin1")
out += " [hang]" if e.pc == h.SYM["beacon_hang"] else " [no hang]"
check("exception via vector 3 prints the beacon", e, out, ["T00000004 00001234 ", "[hang]"])

# ---- source-replay log: fast 256-byte page programming ----
LOG0, LOGN = 0x4000, 0x2800                      # log region (flash offsets)
logbytes = lambda e: bytes(e.f[LOG0:LOG0 + LOGN]).split(b"\xff")[0]
e = copy.deepcopy(B0)
h.feed(e, "+log\n: sq dup * ;\n")
check("log: lines appended (the newline became a space)", e, repr(logbytes(e)),
      [repr(b"+log \n: sq dup * ; \n")])
r = h.boot(flash=bytes(e.f))                     # simulated reset
out, _ = h.feed(r, "3 sq 48 + emit\n")
check("log: replay after reset brings the word back", r, out, ["emit\n9"])
e = copy.deepcopy(B0)
h.feed(e, "+log\n: tw\n2 *\n;\n: bad\nnosuchword\n")
check("log: a definition is logged whole, a failed one not at all", e, repr(logbytes(e)),
      [repr(b"+log \n: tw \n2 * \n; \n")], absent=("bad",))
# a log of many pages (this used to be the prelude, which now lives in flash)
e = copy.deepcopy(B0)
h.feed(e, "+log\n")
errs = 0
for k in range(180):
    out, _ = h.feed(e, f": w{k} {k} 3 * ;\n")
    errs += "  ?" in out
n = len(logbytes(e))
r = h.boot(flash=bytes(e.f))
out, _ = h.feed(r, "w0 w179 + .\n")
check(f"log: 180 definitions logged ({n} bytes) and replayed", r,
      out + f" errs={errs}" + (" [many pages]" if n > 8 * 256 else ""), ["537 ", "errs=0", "[many pages]"])
h.feed(e, "wipe\n")
erased = bytes(e.f[LOG0:LOG0 + LOGN]) == b"\xff" * LOGN
check("log: wipe erases the region", e, "[erased]" if erased else "[NOT erased]", ["[erased]"])
r = h.boot(flash=bytes(e.f))
out, _ = h.feed(r, "w0 .\n")
check("log: nothing is replayed after wipe", r, out, ["  ?"])
img = bytearray(FLASH) + bytearray([0xFF] * (LOG0 - len(FLASH)))
img += b"0 drop \n" * ((LOGN - 8) // 8)          # an almost full log: 8 bytes free
e = h.Emu(bytes(img), b"")
e.gpiod_in = 0x10                                # PD4 held: skip the replay
h.run_idle(e, 100_000)
out, _ = h.feed(e, "+log\n: sq dup * ;\n1 drop\n")
tail = bytes(e.f[LOG0 + LOGN - 8:LOG0 + LOGN])
check("log: a full log turns logging off", e, out + f" tail={tail!r}",
      ["? log off", repr(b"+log \n\xff\xff")])
# the end of the replay: no extra empty line and "ok" after a whole last line,
# none for an empty log, but a partial last line (power cut) is still closed
img = bytearray(FLASH) + bytearray([0xFF] * (LOG0 - len(FLASH)))
for log, expect, absent in ((b": sq dup * ; \n", ": sq dup * ; \n   ok\n", "ok\n\n"),
                            (b"", "sixforths v0.0\n\n", "ok"),
                            (b": sq dup * ;", ": sq dup * ;\n   ok\n", "")):
    e = h.Emu(bytes(img + log), b"")
    h.run_idle(e, 100_000)
    boot = bytes(e.uart_out).decode("latin1")
    out, _ = h.feed(e, "3 sq 48 + emit\n")
    want = [expect] + (["emit\n9"] if log else [])
    check(f"log: replay end, log {log!r}", e, boot + out, want,
          absent=(absent,) if absent else ())
# WeAct board: closed SB3/SB4 join PD4 to PD5; the replay must still run
img = bytearray(FLASH) + bytearray([0xFF] * (LOG0 - len(FLASH))) + b": sq dup * ; \n"
e = h.Emu(bytes(img), b"")
e.weact_bridge = True
h.run_idle(e, 100_000)
out, _ = h.feed(e, "3 sq 48 + emit\n")
check("log: replay runs with PD4 tied to PD5 (WeAct SB3/SB4)", e, out, ["emit\n9"])
h.feed(e, "reboot\n")                            # software reboot: PD5 is TX right now
out, _ = h.feed(e, "3 sq 48 + emit\n")
check("log: ... and after a software reboot", e, out, ["emit\n9"])
# emulator guards: the FPEC model must reject what the V006 cannot do
e = copy.deepcopy(B0)                            # boot unlocked the FPEC
e.f[LOG0] = 0x00                                 # page 0x4000 is not erased
CTLR, ADDR, FTPG = 0x40022010, 0x40022014, 1 << 16
try:
    e.w32(CTLR, FTPG); e.w32(CTLR, FTPG | (1 << 19))
    for i in range(64):
        e.w32(0x08000000 + LOG0 + 4 * i, 0x20202020); e.w32(CTLR, FTPG | (1 << 18))
    e.w32(ADDR, 0x08000000 + LOG0); e.w32(CTLR, FTPG | (1 << 6))
except RuntimeError:
    pass
f, e.fault = e.fault, None
check("emulator: programming an unerased page faults", e, f"fault={f}", ["flash-ftpg-not-erased"])
e = copy.deepcopy(B0)
try:
    e.w16(0x08000000 + LOG0, 0)
except RuntimeError:
    pass
f, e.fault = e.fault, None
check("emulator: halfword flash writes fault", e, f"fault={f}", ["flash-write16"])

# ---- user flash pages ----
UF = 0xE800
e, out, _ = h.session(P, "pad 256 65 fill pad 0x0800E800 fpage-prog 0x0800E800 c@ . 0x0800E8FF c@ .\n")
check("fpage-prog programs a page", e, out + f" {bytes(e.f[UF:UF+256]) == b'A' * 256}", ["65 65 ", "True"])
out, _ = h.feed(e, "pad 0x0800E800 fpage-prog 66 emit\n")
check("fpage-prog refuses a page that is not erased", e, out, ["  ?"], absent=("B",))
out, _ = h.feed(e, "0x0800E8AA fpage-erase 0x0800E800 c@ .\n")
check("fpage-erase (any address in the page)", e, out + f" {bytes(e.f[UF:UF+256]) == bytes([255]) * 256}", ["255 ", "True"])
for name, src in (("the kernel", "0x08000000 fpage-erase"), ("the log", "0x08004000 fpage-erase"),
                  ("the last log page", "0x080067FF fpage-erase"), ("beyond the flash", "0x0800F800 fpage-erase"),
                  ("an alias address", "0x0000E800 fpage-erase"), ("prog into the kernel", "pad 0x08000100 fpage-prog"),
                  ("an unaligned source", "pad 1+ 0x0800E800 fpage-prog")):
    e, out, _ = h.session(P, src + " 66 emit\n")
    same = bytes(e.f[:0x10000]) == bytes(P.f[:0x10000])
    check(f"flash page words refuse {name}", e, out + f" {same}", ["  ?", "True"], absent=("B",))
e, out, _ = h.session(P, "0x0800F7FF fpage-erase 0x08006800 fpage-erase 65 emit\n")
check("first and last user page are allowed", e, out, ["emit\nA"])

# ---- words ----
e, out, _ = h.session(P, "words\n")
names = out.split("\n")[1].split()                # line 0 is the echoed input
print("word count:", len(names))
check("words lists new primitives", e, out, ["um/mod", "xdoes", "find-name", "parse", "um*", "quit"])

print("\nALL PASS" if failures == 0 else f"\n{failures} FAILURES")
sys.exit(1 if failures else 0)
