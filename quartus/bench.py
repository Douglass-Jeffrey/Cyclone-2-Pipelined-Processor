#!/usr/bin/env python3
"""Assemble a benchmark, predict the board's numbers, and install it as program.hex.

    python bench.py programs/bench_sort.S                 assemble + simulate + install
    python bench.py programs/bench_sort.S --no-install    just predict
    python bench.py programs/bench_sort.S --clken half    simulate the 25 MHz clk_en pattern
    python bench.py programs/bench_sort.S --no-install --board
                                                          predict, read the board over
                                                          JTAG, and compare every word

Prints every word the board can report -- all 16 readout words, which carry
every debug output of the core -- with the switch settings that show each one
on the board, so a run is verified rather than merely observed: same halt
rule, same freeze, same counters, in a simulation twin of the wrapper
(tb_bench.v).  --board does the comparison itself: it reads the board through
read_results.tcl after the program has halted and marks each word that differs.

Cache misses are served at CLOCK_50's rate whatever the CPU's speed setting,
so a program with misses takes fewer CPU cycles at 25 MHz than at 50 MHz:
predict with the --clken that matches SW9:8 (full = 50 MHz, half = 25 MHz).
--board picks it from the board's own SW9:8 unless --clken is given.

A benchmark must end in `j .` (the assembler writes that for `halt: j halt`) or
it will never stop, on the board or here.  Whatever it leaves in x28..x31 is
what gets reported back.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VERIF = os.path.join(ROOT, "verif")
sys.path.insert(0, os.path.join(VERIF, "tools"))
import rvsim  # noqa: E402
from rtl_sources import rtl_sources  # noqa: E402  (reads dev/rtl_sources.txt)

# Quartus is not on PATH by default
QUARTUS_STP = shutil.which("quartus_stp") or r"D:\altera\13.0sp1\quartus\bin64\quartus_stp.exe"

# must match soc_top.v's speed encoding (SW9:8)
RATES = {0: ("single step", None), 1: ("~1.5 Hz", 50.0 / 2**25), 2: ("25 MHz", 25.0), 3: ("50 MHz", 50.0)}
CLKEN_FOR_SPEED = {3: "full", 2: "half"}
SPEED_FOR_CLKEN = {"full": 3, "half": 2, "rand": 3}

# readout words by selector, must match soc_top.v's readout() and read_results.tcl
WORDS = ["cycles", "retired", "stalls", "flushes", "x28", "x29", "x30", "x31",
         "status", "retiring pc", "retiring instr", "pc in ID", "write-back data",
         "D-cache misses", "D write-backs", "I-cache misses"]

# status word bits (soc_top.v), low byte
STATUS_BITS = [("halted", 0, 1), ("speed", 1, 2), ("mem_ready", 3, 1), ("reg_write", 4, 1),
               ("retire_valid", 5, 1), ("stall", 6, 1), ("redirect", 7, 1)]


def hexw(v):
    return "%04X_%04X" % (v >> 16, v & 0xFFFF)


def status_text(v):
    if v >> 24 != 0xA5:
        return "no 0xA5 signature: not this design"
    parts = ["v%d" % ((v >> 16) & 0xFF)]
    for name, lo, width in STATUS_BITS:
        f = (v >> lo) & ((1 << width) - 1)
        parts.append("%s=%s" % (name, format(f, "02b") if width == 2 else f))
    return "  ".join(parts)


def print_words(pred, board=None):
    """All 16 words, predicted (and read from the board); returns the mismatch count."""
    print("readout words   (on the board: SW3:0 = word number, SW4=1 shows the upper hex half)")
    print()
    hdr = "  %-4s %-6s %-16s %12s  %-9s" % ("word", "SW3:0", "reading", "predicted", "hex")
    if board is not None:
        hdr += "  %12s  %-9s" % ("board", "hex")
    print(hdr)
    bad = 0
    for sel, label in enumerate(WORDS):
        line = "  %-4d %-6s %-16s %12d  %-9s" % (sel, format(sel, "04b"), label, pred[sel], hexw(pred[sel]))
        if board is not None:
            same = board[sel] == pred[sel]
            bad += not same
            line += "  %12d  %-9s  %s" % (board[sel], hexw(board[sel]), "ok" if same else "<<<")
        print(line)
    print()
    print("  status predicted : " + status_text(pred[8]))
    if board is not None:
        print("  status on board  : " + status_text(board[8]))
    print("  (retire_valid, stall and redirect pulse only while the CPU runs: 0 once halted)")
    return bad


def read_board():
    """Every readout word from the board, through read_results.tcl."""
    r = subprocess.run([QUARTUS_STP, "-t", "read_results.tcl"], cwd=HERE,
                       capture_output=True, text=True)
    words = {int(n): int(h, 16) for n, h in
             re.findall(r"^\s*word\s+(\d+)\s.*0x([0-9A-Fa-f]{8})\s*$", r.stdout, re.M)}
    if len(words) != 16:
        tail = "\n".join((r.stdout + r.stderr).strip().splitlines()[-8:])
        sys.exit("could not read the board over JTAG:\n" + tail)
    if words[8] >> 24 != 0xA5 or (words[8] >> 16) & 0xFF != 3:
        sys.exit("the board is not running this soc_top build (status %08X): reprogram it" % words[8])
    return words


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="benchmark .S to assemble")
    ap.add_argument("--no-install", action="store_true",
                    help="do not overwrite quartus/program.hex")
    ap.add_argument("--no-sim", action="store_true",
                    help="skip the prediction (for demos that never halt)")
    ap.add_argument("--max", type=int, default=20_000_000, help="cycle ceiling")
    ap.add_argument("--clken", choices=("full", "half", "rand"),
                    help="clk_en pattern: full = the 50 MHz setting (default), half = 25 MHz")
    ap.add_argument("--board", action="store_true",
                    help="read the board over JTAG after it halts and compare every word")
    args = ap.parse_args()

    # read the board first, so the prediction can use its speed setting
    board = None
    if args.board:
        board = read_board()
        speed = (board[8] >> 1) & 3
        if not board[8] & 1:
            sys.exit("the board has not halted yet (SW9:8 = %s, %s): set SW9:8 = 11, press KEY0, "
                     "and try again" % (format(speed, "02b"), RATES[speed][0]))
        if args.clken is None:
            args.clken = CLKEN_FOR_SPEED.get(speed, "full")
            if speed not in CLKEN_FOR_SPEED:
                print("NOTE: the board ran at %s; predicting for 50 MHz, so cycles may differ "
                      "(misses cost less there)" % RATES[speed][0])
    if args.clken is None:
        args.clken = "full"

    # build/bench/tb_bench.vvp is shared; each program gets build/bench/<name>/
    bench_root = os.path.join(ROOT, "build", "bench")
    name = os.path.splitext(os.path.basename(args.source))[0]

    build = os.path.join(bench_root, name)
    shutil.rmtree(build, ignore_errors=True)    # never report a stale prediction
    os.makedirs(build)
    # tb_bench.v reads program.hex from the folder vvp is started in
    hexp = os.path.join(build, "program.hex")
    words = rvsim.assemble(args.source, hexp)   # also writes program.elf / .bin here
    print("assembled %-28s %d instructions" % (os.path.basename(args.source), len(words)))
    if len(words) > 2048:
        print("  WARNING: the I-cache preload holds 2048 words (8 KB); this program will be truncated.")

    if args.no_sim:
        if not args.no_install:
            shutil.copy(hexp, os.path.join(HERE, "program.hex"))
            print("installed -> quartus/program.hex   (recompile, then program the board)")
        return

    vvp = os.path.join(bench_root, "tb_bench.vvp")
    cmd = ["iverilog", "-g2005", "-I", os.path.join(ROOT, "dev"), "-o", vvp,
           os.path.join(VERIF, "tb", "tb_bench.v"), os.path.join(VERIF, "tb", "sram_model.v")] + \
          rtl_sources(os.path.join(ROOT, "dev"))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr)

    speed = (board[8] >> 1) & 3 if board else SPEED_FOR_CLKEN[args.clken]
    r = subprocess.run(["vvp", vvp, "+max=%d" % args.max, "+clken=%s" % args.clken,
                        "+speed=%d" % speed], cwd=build, capture_output=True, text=True)
    out = r.stdout
    if "ERROR" in out + r.stderr:          # e.g. $readmemh could not open the program
        sys.exit(out + r.stderr)
    if "HALTED" not in out:
        print(out.strip())
        sys.exit("benchmark did not halt -- does it end with `j .`?")

    pred = {int(n): int(x) for n, x in re.findall(r"^word(\d+)=(\d+)$", out, re.M)}
    cyc, ret = pred[0], pred[1]

    print()
    bad = print_words(pred, board)
    print()
    label, mhz = RATES[speed]
    print("  CPI      : %.4f   (%s clk_en pattern)" % (cyc / ret, args.clken))
    if mhz and mhz > 1:
        print("  at %-8s: %.3f ms, %.2f MIPS" % (label, cyc / (mhz * 1000.0), ret * mhz / cyc))

    if board is not None:
        print()
        if bad:
            print("BOARD MISMATCH: %d of 16 words differ (marked <<<)" % bad)
        else:
            print("BOARD MATCHES: all 16 words agree with the prediction")

    if not args.no_install:
        shutil.copy(hexp, os.path.join(HERE, "program.hex"))
        print()
        print("installed -> quartus/program.hex   (recompile, then program the board)")

    if board is not None and bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
