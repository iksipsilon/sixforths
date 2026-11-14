#!/usr/bin/env python3
"""Check the hand-written threads in src/10-forth-words.s against the compiler.

Every defword there carries its Forth source in the comment above it
(`# : name ... ;`, optionally `immediate`). This script types that source into
the kernel running in the emulator, lets the kernel's own compiler build the
word in RAM, and compares the result cell by cell with the thread in flash
(branch targets are compared as offsets). Run it after editing a thread or
adding one:

    make && python3 emulators/check_threads.py

A MISMATCH line shows both cell lists. The comment is the reference, so fix
whichever of the two is wrong.
"""
import sys, re, copy, os
HERE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE_DIR)
import harness as h
FLASH = open(h.BIN, "rb").read()
B0 = h.boot()
HEREVAR = h.SYM["var_HERE"]
def fw(a): return int.from_bytes(FLASH[a:a+4], "little")
PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE_DIR, "..", "src", "10-forth-words.s")
L = open(PATH).read().split("\n")
bad = n = 0
i = 0
while i < len(L):
    m = re.match(r'^defword "(.*)",(\d+),([A-Z_]*),(\w+)', L[i])
    if m:
        label = m.group(4)
        j = i
        while j > 0 and L[j-1].startswith("#"): j -= 1
        src = " ".join(l[1:].strip() for l in L[j:i])
        k = src.find(": ")
        end = src.find(" ;", k)
        if k < 0 or end < 0:
            print("no source for", label); bad += 1; i += 1; continue
        src = src[k:end+2] + (" immediate" if "immediate" in src[end:end+12] else "")
        e = copy.deepcopy(B0)
        here0 = h.ram_word(e, HEREVAR)
        out, _ = h.feed(e, src + "\n")
        if "?" in out.split("\n", 1)[1] or e.fault:
            print("COMPILE FAIL", label, repr(out), e.fault); bad += 1; i += 1; continue
        here1 = h.ram_word(e, HEREVAR)
        name = src.split()[1]
        cfa_ram = (here0 + 4 + 1 + len(name) + 3) & ~3
        cells_ram = [h.ram_word(e, a) for a in range(cfa_ram + 4, here1, 4)]
        cfa_fl = h.SYM[label]
        cells_fl = [fw(a) for a in range(cfa_fl + 4, cfa_fl + 4 + 4*len(cells_ram), 4)]
        ok = fw(cfa_fl) == h.SYM["docol"]
        for r, f in zip(cells_ram, cells_fl):
            if r == f: continue
            if 0x20000000 <= r < 0x20002000 and r - (cfa_ram + 4) == f - (cfa_fl + 4): continue   # branch target
            ok = False
        # the cell after the thread must not be part of it: the flash thread ends with EXIT at the same place
        ok = ok and cells_fl[-1] == h.SYM["EXIT"]
        imm_ram = e.ram[here0 - 0x20000000 + 4] & 0x80
        imm_fl = FLASH[h.SYM["name_" + label] + 4] & 0x80
        ok = ok and imm_ram == imm_fl
        n += 1
        if not ok:
            bad += 1
            print("MISMATCH", label, src)
            print("   compiled:", [hex(c) for c in cells_ram])
            print("   flash   :", [hex(c) for c in cells_fl])
    i += 1
print(f"{n} threads compared with the compiler's output, {bad} problems")
sys.exit(1 if bad else 0)
