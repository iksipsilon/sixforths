#!/usr/bin/env python3
"""Boot fotrh.bin in the RV32EC emulator and feed it Forth sessions.

Idle detection: the interpreter is idle when the PC sits on the hardware
UART receive loop with no input left. Any silicon-modelled fault (misaligned
access, bad FPEC sequence, RV32E register use, unknown instruction) is
reported rather than swallowed.
"""
import copy, subprocess, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rv32emu import Emu

ELF = os.path.join(HERE, "..", "sixforths.elf")
BIN = os.path.join(HERE, "..", "sixforths.bin")

def symbols():
    out = subprocess.check_output(["riscv64-unknown-elf-nm", ELF]).decode()
    syms = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3:
            syms[p[2]] = int(p[0], 16)
    return syms

SYM = symbols()
IDLE = SYM["uart_get_loop"]

def run_idle(e, max_steps=60_000_000):
    n = 0
    try:
        while n < max_steps:
            if e.pc == IDLE and not e.uart_in:
                return n
            e.step()
            n += 1
    except RuntimeError:
        pass
    return -1

def boot(flash=None):
    flash = flash if flash is not None else open(BIN, "rb").read()
    e = Emu(flash, b"")
    run_idle(e)
    return e

def feed(e, text, max_steps=60_000_000):
    """Feed text to emulator e in place; return output produced."""
    start = len(e.uart_out)
    e.uart_in = list(text.encode())
    e.fault = None
    steps = run_idle(e, max_steps)
    return bytes(e.uart_out[start:]).decode("latin1"), steps

def session(booted, text, max_steps=60_000_000):
    e = copy.deepcopy(booted)
    out, steps = feed(e, text, max_steps)
    return e, out, steps

def ram_word(e, addr):
    o = addr - 0x20000000
    return int.from_bytes(e.ram[o:o+4], "little")

if __name__ == "__main__":
    e = boot()
    print("fault:", e.fault)
    print("banner:", bytes(e.uart_out).decode("latin1"))
