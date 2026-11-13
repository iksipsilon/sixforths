#!/usr/bin/env python3
"""Talk to the sixforths REPL on the board over the WCH-LinkE UART (/dev/ttyACM0).

Run from the repo root. Every command below touches the board; flashing and
anything that writes flash needs the owner's go-ahead first (CLAUDE.md rule 3).

    python3 etc/board.py lines "5 6 + ." "words"   send each line, print what the board answers
    python3 etc/board.py timed "5000 ms"            the same for one line, plus the PC's time
                                                    from the echoed newline to "ok"
    python3 etc/board.py reset                      hardware reset (minichlink -b), print the boot
    python3 etc/board.py flash                      minichlink -w sixforths.bin flash -b, print the boot
    python3 etc/board.py flash-and-wipe             the same, then send `wipe` as the very first
                                                    line (erases the log: only with consent)

Each character waits for its echo before the next one goes out (the board's
receiver holds only 1-2 bytes, and the board does not read the UART while it
runs a line). Each line then waits for "ok" or "?" - not for a pause, since a
line like `5000 ms` prints nothing for seconds. After "ok rebooting" it reads
on until the board has been quiet for 1.5 s, so the banner belongs to that
line and the next line starts in step. A trap line "T<mcause> <mepc>"
is flagged; reset the chip with `minichlink -b` after one.
Close picocom first: two programs reading the port steal each other's bytes.
Saved from the 2026-11-12 session, where phase 2 steps 1-5a were tested with it.
"""
import os, re, subprocess, sys, time
import serial

PORT = "/dev/ttyACM0"
REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TRAP = re.compile(rb"(^|\n)T[0-9A-Fa-f]{1,8} [0-9A-Fa-f]{1,8}")
DONE = re.compile(rb"(   ok\n| {2,3}\?[^\n]*\n)$")
REBOOTING = b"   ok rebooting\n"      # the banner follows at once, so it is never at the end

def show(label, data):
    print(f"--- {label} ---")
    print(data.decode("latin1"), end="" if data.endswith(b"\n") else "\n")
    if TRAP.search(data):
        print("!!! TRAP LINE SEEN: the chip is hung, reset it with minichlink -b")

def drain(s, idle=1.5, total=20.0, proc=None):
    """Read until the board is quiet for `idle` s (and proc, if any, has ended)."""
    buf, t0, last = b"", time.time(), time.time()
    while time.time() - t0 < total:
        c = s.read(4096)
        if c:
            buf += c
            last = time.time()
        running = proc is not None and proc.poll() is None
        if not running and time.time() - last > idle:
            break
    return buf

def send_line(s, line, total=60.0):
    """Send one line, echo-synced; return everything up to "ok" or "?"."""
    left = s.read(4096)
    if left:
        show("unexpected output before the line", left)
    out = b""
    data = line.encode() + b"\n"
    for i, ch in enumerate(data):
        s.write(bytes([ch]))
        t0 = time.time()
        while len(out) < i + 1:                  # wait for this character's echo
            out += s.read(1)
            if time.time() - t0 > 2.0:
                show(f"NO ECHO after {i} characters of {line!r}", out)
                return out
    t0, last = time.time(), time.time()
    while time.time() - t0 < total:
        c = s.read(s.in_waiting or 1)
        if c:
            out += c
            last = time.time()
        if REBOOTING in out:
            out += drain(s, idle=1.5, total=30.0)    # the banner, and any log replay
            break
        if DONE.search(out):
            break
        if TRAP.search(out) and time.time() - last > 1.0:
            break                                # hung in the trap handler
    else:
        show(f"NO ok OR ? within {total:.0f} s for {line!r}", out)
    return out

def minichlink(*args):
    return subprocess.Popen(["minichlink", *args], cwd=REPO,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

def boot_after(s, p):
    boot = drain(s, idle=2.5, total=60.0, proc=p)
    print("--- minichlink ---")
    print(p.stdout.read().decode(errors="replace"), end="")
    print("minichlink exit status:", p.returncode)
    show("boot output", boot)
    return boot

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd, rest = sys.argv[1], sys.argv[2:]
    s = serial.Serial(PORT, 115200, timeout=0.05)
    s.reset_input_buffer()
    if cmd in ("flash", "flash-and-wipe"):
        boot = boot_after(s, minichlink("-w", "sixforths.bin", "flash", "-b"))
        if cmd == "flash-and-wipe":
            if TRAP.search(boot) or b"sixforths" not in boot:
                print("!!! not sending wipe: the flash or the boot did not go as expected")
                return 1
            show("wipe", send_line(s, "wipe"))
    elif cmd == "reset":
        boot_after(s, minichlink("-b"))
    elif cmd == "lines":
        for line in rest:
            out = send_line(s, line)
            show(line, out)
            if TRAP.search(out):
                return 1
    elif cmd == "timed":
        line = rest[0]
        for ch in line.encode():                 # echo-synced, as in send_line
            s.write(bytes([ch]))
            while not s.read(1):
                pass
        s.write(b"\n")
        out = b""
        while b"\n" not in out:
            out += s.read(1)
        t_start = time.monotonic()
        while not (DONE.search(out) or REBOOTING in out) and time.monotonic() - t_start < 60:
            out += s.read(s.in_waiting or 1)
        t_end = time.monotonic()
        show(line, line.encode() + out)
        print(f"PC time from the echoed newline to ok: {t_end - t_start:.3f} s")
    else:
        print(__doc__)
        return 2
    return 0

if __name__ == "__main__":
    sys.exit(main())
