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

# ---- RAM map (01-variables-constants.s): the blocks follow each other with no gap and no overlap ----
S = h.SYM
a, gaps = S["DICT_TOP"], []
for name, size in (("FRAME", "FRAME_SIZE"), ("MLINE", "MLINE_SIZE"), ("MRING", "MRING_SIZE"),
                   ("LOGBUF", "LOGBUF_SIZE"), ("PAD", "PAD_SIZE"), ("MSP_BOTTOM", "MSTACK_SIZE")):
    if S[name] != a or a % 4:
        gaps.append(name)
    a += S[size]
# the variables: every cell from the top of the machine stack up to the TIB, each used once.
# A variable added without moving MSP_TOP would lie inside the machine stack and fail here.
cells = sorted(v for k, v in S.items() if k.startswith("var_") or False)
check("RAM map: dictionary, buffers, machine stack, variables, TIB and stacks fill the RAM exactly", B0,
      f"gaps={gaps} stack_top={a == S['MSP_TOP']} cells={cells == list(range(S['MSP_TOP'], S['TIB_BOTTOM'], 4))} "
      f"dict={S['FORTH_SIZE'] == S['DICT_TOP'] - S['RAM_BASE']} "
      f"top={S['TIB_BOTTOM'] + 3 * 256 == S['DSP_TOP'] == S['RAM_BASE'] + S['RAM_SIZE']}",
      ["gaps=[]", "stack_top=True", "cells=True", "dict=True", "top=True"])

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
print(f"prelude loaded in {time.time()-t0:.1f}s; HERE-RAM_BASE = {h.ram_word(E, h.SYM["var_HERE"]) - 0x20000000} bytes of dictionary")

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

# 62 loop results plus the two loop parameters of the second loop = 64 cells
t("64 cells fit on the data stack", ": f64 62 0 do i loop 62 0 do drop loop 65 emit ; f64", "f64\nA")
t("the 65th overflows", ": f65 63 0 do i loop 63 0 do drop loop 65 emit ; f65", "? stack overflow", absent=("f65\nA",))
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

# a definition that runs out of dictionary is dropped whole, wherever it runs
# out: in its header, a number, a word, or at ; (zz takes 40 or 28 bytes)
TOP = h.SYM["DICT_TOP"]
for body, size in (("1 2 3", 40), ("dup dup dup", 28)):
    for room in range(4, size + 8, 4):
        e, out, _ = h.session(P, f"{TOP} here @ - {room} - allot : zz {body} ;\n"
                                 f"here @ {TOP} > . 65 emit\nzz\n")
        full, fits = "memory full" in out, room >= size
        gone = out.rstrip().endswith("?")      # zz unknown: it was dropped
        check(f"dictionary full, {room} bytes left for {size}: dropped whole", e,
              out[-40:] + f" full={full != fits} gone={gone != fits}", ["0 A", "full=True", "gone=True"],
              absent=())

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
# vocabularies come back from the lines in flash
FLASH = open(h.BIN, "rb").read()
LINES0, LINESN = 0x4000, 0x2800                  # the lines (flash offsets)
def image(lines):
    """The kernel plus the lines {number: text}, as a whole flash image."""
    reg = bytearray([0xFF] * LINESN)
    for n, text in lines.items():
        reg[64 * n:64 * n + len(text) + 1] = text.encode() + b"\n"
    return bytes(FLASH) + bytes([0xFF] * (LINES0 - len(FLASH))) + bytes(reg)
r = h.boot(flash=image(dict(enumerate(["1 3 load"] + VOC.strip().split("\n")))))
out, _ = h.feed(r, "k3 edit k3 forth k3\n")
check("vocabularies come back with the lines", r, out, ["forth k3\nGFG"])

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

# ---- source lines: load, and line 0 at boot ----
LOG0 = LINES0
def booted(lines, pd4=0, bridge=False):
    e = h.Emu(image(lines), b"")
    e.gpiod_in, e.weact_bridge = pd4, bridge
    h.run_idle(e, 400_000_000)
    return e, bytes(e.uart_out).decode("latin1")
e, boot = booted({0: ": sq dup * ;"})
out, _ = h.feed(e, "3 sq 48 + emit\n")
check("lines: line 0 is loaded at boot, echoed as typed", e, boot + out, ["sixforths v0.0\n\n: sq dup * ;\n   ok\n", "emit\n9"], absent=("ok\n\n", "ok\n   ok"))
e, boot = booted({})
check("lines: an empty line 0 loads nothing", e, boot + "|", ["sixforths v0.0\n\n|"])
e, boot = booted({1: ": sq dup * ;"})
out, _ = h.feed(e, "3 sq\n")
check("lines: only line 0 is loaded at boot", e, boot + out, ["  ?"], absent=(": sq",))
e, boot = booted({0: ": sq dup * ;"}, pd4=0x10)
out, _ = h.feed(e, "3 sq\n")
check("lines: PD4 held, nothing is loaded", e, boot + out, ["  ?"], absent=(": sq",))
e, boot = booted({0: "nosuchword", 1: ": sq dup * ;"})
out, _ = h.feed(e, "65 emit\n")
check("lines: a bad line 0 prints ? and the console works", e, boot + out, ["nosuchword\n  ?\n", "emit\nA"])
e, boot = booted({0: "4 6 load", 4: ": tw", 6: "2 * ;", 7: ": no 1 ;"})
out, _ = h.feed(e, "5 tw . no\n")
check("lines: line 0 loads a range; a definition over lines, an erased line between", e, boot + out,
      ["4 6 load\n   ok\n: tw\n   ok\n2 * ;\n   ok\n", "10   ?"])
assert len(": xx " + "1 drop " * 8 + " ;") == 63
e, boot = booted({})
e.f[LINES0:LINES0 + LINESN] = image({20: ": sq dup * ;", 21: ": cube dup sq * ;", 22: "nosuchword", 23: ": late 1 ;",
                                     30: ": xx " + "1 drop " * 8 + " ;", 31: "65 emit", 40: "66 emit 20 20 load 67 emit", 159: ": top 9 ;"})[LINES0:]
t0e = copy.deepcopy(e)
def lt(name, src, *expect, absent=()):
    x = copy.deepcopy(t0e)
    out, _ = h.feed(x, src + "\n")
    check("lines: " + name, x, out, list(expect), absent=absent)
lt("load", "20 21 load\n3 cube .", ": cube dup sq * ;\n   ok\n", "27 ")
lt("what follows load on its line runs first", "20 20 load 65 emit", "emit\nA   ok\n: sq dup * ;\n   ok\n")
lt("an error abandons the rest", "20 23 load\n3 cube . late", "nosuchword\n  ?\n", "27   ?", absent=(": late",))
lt("a full 63-character line does not merge with the next", "30 31 load", " ;\n   ok\n65 emit\nA   ok\n")
lt("a load in a loaded line replaces the range", "40 41 load\n2 sq .", "BC   ok\n: sq dup * ;\n   ok\n", "4 ")
lt("load the last line", "159 159 load\ntop .", "9 ")
lt("load of erased lines", "100 158 load\n65 emit", "load\n   ok\n65 emit\nA")
lt("load backwards", "21 20 load 65 emit", "  ?", absent=("A",))
lt("load beyond the last line", "159 160 load 65 emit", "  ?", absent=("A",))
lt("load from a negative line", "-1 3 load 65 emit", "  ?", absent=("A",))
lt("load needs two numbers", "3 load", "underflow")
lt("line", "0 line u. 1 line 0 line - . 159 line hex u.", "134234112 64 80067C0 ")
lt("line beyond the last", "160 line", "  ?")
lt("line -1", "-1 line", "  ?")
lt("line reads the text", "20 line c@ emit 20 line 12 + c@ .", ":10 ")
e = copy.deepcopy(t0e)
e.f[LINES0 + 5 * 256:LINES0 + 6 * 256] = b"\xff" * 256      # a power cut left the page of lines 20-23 erased
out, _ = h.feed(e, "20 31 load\n")
check("lines: an erased page is skipped", e, out, ["65 emit\nA"])
src = {0: "1 159 load"}
src.update({k: f": w{k} {k} ;" for k in range(1, 160)})
e, boot = booted(src)
out, _ = h.feed(e, "w1 w159 + .\n")
check("lines: all 160 lines loaded at boot", e, out, ["160 "])
h.feed(e, "wipe\n")
erased = bytes(e.f[LINES0:LINES0 + LINESN]) == b"\xff" * LINESN
check("lines: wipe erases them all", e, "[erased]" if erased else "[NOT erased]", ["[erased]"])
r = h.boot(flash=bytes(e.f))
out, _ = h.feed(r, "w1 .\n")
check("lines: nothing is loaded after wipe", r, out, ["  ?"])
# WeAct board: closed SB3/SB4 join PD4 to PD5; line 0 must still load
e, boot = booted({0: ": sq dup * ;"}, bridge=True)
out, _ = h.feed(e, "3 sq 48 + emit\n")
check("lines: line 0 loads with PD4 tied to PD5 (WeAct SB3/SB4)", e, out, ["emit\n9"])
h.feed(e, "reboot\n")                            # software reboot: PD5 is TX right now
out, _ = h.feed(e, "3 sq 48 + emit\n")
check("lines: ... and after a software reboot", e, out, ["emit\n9"])
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
for name, src in (("the kernel", "0x08000000 fpage-erase"), ("the lines", "0x08004000 fpage-erase"),
                  ("the last page of the lines", "0x080067FF fpage-erase"), ("beyond the flash", "0x0800F800 fpage-erase"),
                  ("an alias address", "0x0000E800 fpage-erase"), ("prog into the kernel", "pad 0x08000100 fpage-prog"),
                  ("an unaligned source", "pad 1+ 0x0800E800 fpage-prog")):
    e, out, _ = h.session(P, src + " 66 emit\n")
    same = bytes(e.f[:0x10000]) == bytes(P.f[:0x10000])
    check(f"flash page words refuse {name}", e, out + f" {same}", ["  ?", "True"], absent=("B",))
e, out, _ = h.session(P, "0x0800F7FF fpage-erase 0x08006800 fpage-erase 65 emit\n")
check("first and last user page are allowed", e, out, ["emit\nA"])

# ---- ticks and ms (the emulator's SysTick counts one HCLK cycle per instruction) ----
t("SysTick runs on HCLK/8, no reload, compare interrupt on", "0xE000F000 @ .", "\n3 ")
t("ticks advances, by less than 1 ms", "ticks ticks swap - dup 0> . 3000 < .", "-1 -1 ")
t("10 ms waits 30000 ticks", "ticks 10 ms ticks swap - dup 30000 < . 33000 < .", "0 -1 ")
t("0 ms and -5 ms return at once", "ticks 0 ms -5 ms ticks swap - 3000 < .", "-1 ")
t("ms across the wrap", "0xFFFFF000 0xE000F008 ! ticks 2 ms ticks over 0xF0000000 u> . dup 0x10000 u< . swap - dup 6000 < . 9000 < .",
  "-1 -1 0 -1 ")
t("ms on an empty stack", "ms", "? stack underflow", absent=())

# ---- the tick: SysTick's compare interrupt every 2 ms (HPE frame below sp, mret) ----
t("10 ticks in 20 ms", "irqs 20 ms irqs swap - dup 9 < . 11 > .", "\n0 0 ")
t("the next compare is ahead of the count", "0xE000F010 @ ticks - dup 0> . 6001 < .", "\n-1 -1 ")
e = copy.deepcopy(P)
e.csr[0x300] &= ~8                                  # interrupts held off for 30 ms, as by flash work
h.feed(e, "30 ms\n")
pending = e.stk_cntif
e.csr[0x300] |= 8
out, _ = h.feed(e, "irqs 20 ms irqs swap - dup 9 < . 11 > .\n")
check("after a 30 ms stall the tick goes on", e, out + f" pending={pending}", ["\n0 0 ", "pending=1"])
e, out, _ = h.session(P, ": deep 40 0 do i loop 20 ms 0 40 0 do swap 39 i - <> if 1+ then loop ; deep .\n")
check("a 40-cell data stack survives 20 ms of ticks", e, out + f" enough={e.irqs_taken - P.irqs_taken >= 9}",
      ["deep .\n0 ", "enough=True"])
t("the tick runs after reboot", "reboot\nirqs 20 ms irqs swap - dup 9 < . 11 > .", "\n0 0 ")
t("the tick runs after an error", "nosuchword\nirqs 20 ms irqs swap - dup 9 < . 11 > .", "\n0 0 ", absent=())
# the data stack pointer is not sp any more: a wild one ends in an error, not in a trap
t("0 sp! then ticks: an error, no trap", "0 sp! 20 ms 1\n65 emit", "emit\nA", absent=("T0",))
t("sp! unaligned: an error", "1 2 sp@ 2 + sp!\n65 emit", "sp!\n  ?", "emit\nA", absent=("T0",))
t("sp! below the data stack: an error", "r0 4 - sp!\n65 emit", "sp!\n  ?", "emit\nA", absent=("T0",))
t("sp! to both ends of the data stack", "1 2 3 s0 sp! depth . : t r0 sp! 2drop 2drop sp@ >r s0 sp! r> r0 - . ; t", "\n0 16 ")
t("rp! unaligned: an error", "r0 2 - rp!\n65 emit", "rp!\n  ?", "emit\nA", absent=("T0",))
t("rp! above the return stack: an error", "r0 4 + rp!\n65 emit", "rp!\n  ?", "emit\nA", absent=("T0",))
t("rp! below the return stack: an error", "tib rp!\n65 emit", "rp!\n  ?", "emit\nA", absent=("T0",))
t("r0 rp! at the console changes nothing", "r0 rp! 65 emit", "emit\nA")
# the error message does not go through the return stack pointer
t("0 rp! then an error: the message, no trap", "0 rp! nosuchword\n65 emit", "nosuchword\n  ?", "emit\nA", absent=("T0",))
t("an sp! above the stack: an error, no trap", "-4 sp! 20 ms 1\n65 emit", "emit\nA", absent=("T0",))
# a tick just before any instruction of reset (the error path) does no harm: sp is always whole
lo, hi = h.SYM["reset"], h.SYM["ram_init"]
e = copy.deepcopy(P); e.uart_in = list(b"nosuchword\n")
seen = []
for _ in range(200_000):
    if lo <= e.pc < hi and e.pc not in seen:
        seen.append(e.pc)
    if e.pc == h.IDLE and not e.uart_in:
        break
    e.step()
bad = []
for a in seen:
    e = copy.deepcopy(P); e.uart_in = list(b"nosuchword\n65 emit\n")
    for _ in range(200_000):
        if e.pc == a:
            break
        e.step()
    e.stk_cntif = 1                                 # the tick arrives right now
    taken = e.irqs_taken
    h.run_idle(e)
    if e.fault or "emit\nA" not in bytes(e.uart_out).decode("latin1") or e.irqs_taken == taken:
        bad.append(hex(a))
check(f"a tick before each of the {len(seen)} instructions of reset", e, f"bad={bad}", ["bad=[]"])

# ---- modem: USART2 + DMA channel 7 into the ring (the emulator delivers a byte per 2083 instructions) ----
def tm(name, src, *expect, modem=b"", loop=False, absent=("  ?",)):
    """modem: bytes the modem sends; loop: a wire from PD2 (TX) to PD3 (RX)."""
    e = copy.deepcopy(P)
    e.uart2_in, e.uart2_loopback = list(modem), loop
    out, steps = h.feed(e, src + "\n")
    check(name, e, out, list(expect), absent)
    return e, out

tm("USART2 115200 8N1 with DMAR, channel 7 circular into the ring",
   "0x40004408 @ . 0x4000440C @ . 0x40004414 @ . 0x40020080 @ . 0x40020084 @ . 0x4002008C @ .",
   f"208 8204 64 161 256 {h.SYM['MRING']} ")
tm("clocks, PD2/PD3 remap and pins", "0x40021014 @ 1 and . 0x40021018 @ 8193 and . 0x4001000C @ 20 rshift 7 and . "
   "0x40011400 @ 8 rshift 255 and . 0x4001140C @ 8 and .", "1 8193 3 137 8 ")
tm("mtimeout is 1000 at boot", "mtimeout @ .", "1000 ")
tm("mkey? with nothing from the modem", "mkey? .", "0 ")
tm("mkey? sees a byte, mkey takes it", "1 ms mkey? . mkey emit mkey? .", "-1 A0 ", modem=b"A")
tm("mkey reads what the modem sent", "mkey emit mkey emit mkey . mkey .", "OK13 10 ", modem=b"OK\r\n")
tm("mkey gives -1 after mtimeout ms", "10 mtimeout ! ticks mkey . ticks swap - dup 30000 < . 33000 < .", "-1 0 -1 ")
tm("0 mtimeout: mkey does not wait", "0 mtimeout ! ticks mkey . ticks swap - 3000 < .", "-1 -1 ")
tm("negative mtimeout: mkey does not wait", "-5 mtimeout ! ticks mkey . ticks swap - 3000 < .", "-1 -1 ")
e, out = tm("memit sends to the modem", "65 memit 66 memit 0x1143 memit")
check("memit sends the low byte", e, repr(bytes(e.uart2_out)), ["b'ABC'"])
tm("memit on an empty stack", "memit", "? stack underflow", absent=())
tm("loopback: memit comes back through mkey", "65 memit mkey .", "mkey .\n65 ", loop=True)
tm("300 bytes through the 256-byte ring, read as they come",
   ": lb 0 300 0 do i 255 and dup memit mkey <> if 1+ then loop ; lb .", "lb .\n0 ", loop=True)
tm("300 unread bytes: the ring keeps only the last 44",
   ": drain 0 begin mkey? while mkey drop 1+ repeat ; 30 ms mkey emit drain .", "B43 ",
   modem=b"a" * 256 + b"B" * 44)
tm("an error keeps the unread modem bytes", "1 ms nosuchword\nmkey emit mkey emit", "  ?", "XY", modem=b"XY",
   absent=())
tm("after reboot the modem works again", "reboot\n65 memit mkey .", "mkey .\n65 ", loop=True)

# ---- vectored output and input: >console >modem <console <modem ----
def tv(name, src, console, to_modem, modem=b"", loop=False, absent=("  ?",), exact=True):
    """console: substrings the console must show; to_modem: what the modem must get."""
    e = copy.deepcopy(P)
    e.uart2_in, e.uart2_loopback = list(modem), loop
    out, steps = h.feed(e, src + "\n")
    got = bytes(e.uart2_out)
    same = got == to_modem if exact else to_modem in got
    check(name, e, out + f" [modem {'ok' if same else 'got ' + repr(got)}]", list(console) + ["[modem ok]"], absent)

tv(">modem: emit goes to the modem", ">modem 65 emit >console 66 emit", ["emit\nB   ok"], b"A")
tv(">modem: . space cr", ">modem 42 . space cr >console", ["\n   ok"], b"42  \r\n")
tv('>modem: ." and type in a definition', ': at ." AT" s" +CSQ" type 13 emit ; >modem at >console', ["\n   ok"],
   b"AT+CSQ\r")
tv(">modem: words", ">modem words >console", [">console\n   ok"], b" <modem >modem mtimeout ", exact=False)
tv("the echo and ok stay on the console", ">modem 66 emit\n67 emit", [">modem 66 emit\n   ok\n67 emit\n   ok"], b"BC")
tv("an error switches back to the console", ">modem <modem nosuchword\n65 emit key? .", ["  ?", "key? .\nA0 "], b"",
   absent=())
tv("reboot switches back to the console", ">modem reboot\n65 emit", ["emit\nA"], b"", absent=())
tm("<modem: key reads the modem", "<modem key emit key emit <console", "<console\nOK", modem=b"OK")
tm("<modem: key? sees a modem byte", "<modem 1 ms key? . key emit key? . <console", "-1 Q0 ", modem=b"Q")
tm("<modem: key gives -1 after mtimeout", "10 mtimeout ! <modem key . <console", "<console\n-1 ")
tm("<console: key reads the console again", "<modem <console key emit\nZ", "emit\nZ")
tm(">modem emit, <modem key: round trip over the wire", ">modem 72 emit >console <modem key emit <console",
   "<console\nH", loop=True)

# ---- words ----
e, out, _ = h.session(P, "words\n")
names = out.split("\n")[1].split()                # line 0 is the echoed input
print("word count:", len(names))
check("words lists new primitives", e, out, ["um/mod", "xdoes", "find-name", "parse", "um*", "quit"])
check("words lists the modem words, then ms and ticks", e, out, ["\n <modem >modem mtimeout memit mkey mkey? ms ticks irqs fpage-prog fpage-erase wipe load line "])

print("\nALL PASS" if failures == 0 else f"\n{failures} FAILURES")
sys.exit(1 if failures else 0)
