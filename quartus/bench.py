#!/usr/bin/env python3
"""Assemble a benchmark, predict the board's numbers, and install it as program.hex.

    python bench.py programs/bench_sort.S          assemble + simulate + install
    python bench.py programs/bench_sort.S --no-install   just predict

Prints exactly the figures `read_results.tcl` will report from the board, so a
run is verified rather than merely observed: same halt rule, same counters,
same x28..x31 capture, in a simulation twin of the wrapper (tb_bench.v).

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

# must match soc_top.v's speed encoding
RATES = {0: ("~3 Hz", 3e-6), 1: ("~95 Hz", 95e-6), 2: ("25 MHz", 25.0), 3: ("12.5 MHz", 12.5)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="benchmark .S to assemble")
    ap.add_argument("--no-install", action="store_true",
                    help="do not overwrite quartus/program.hex")
    ap.add_argument("--no-sim", action="store_true",
                    help="skip the prediction (for demos that never halt)")
    ap.add_argument("--max", type=int, default=20_000_000, help="cycle ceiling")
    args = ap.parse_args()

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
    if len(words) > 512:
        print("  WARNING: imem holds 512 words; this program will be truncated.")

    if args.no_sim:
        if not args.no_install:
            shutil.copy(hexp, os.path.join(HERE, "program.hex"))
            print("installed -> quartus/program.hex   (recompile, then program the board)")
        return

    vvp = os.path.join(bench_root, "tb_bench.vvp")
    cmd = ["iverilog", "-g2005", "-I", os.path.join(ROOT, "dev"), "-o", vvp,
           os.path.join(VERIF, "tb", "tb_bench.v")] + \
          rtl_sources(os.path.join(ROOT, "dev"))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr)

    r = subprocess.run(["vvp", vvp, "+max=%d" % args.max], cwd=build,
                       capture_output=True, text=True)
    out = r.stdout
    if "ERROR" in out + r.stderr:          # e.g. $readmemh could not open the program
        sys.exit(out + r.stderr)
    if "HALTED" not in out:
        print(out.strip())
        sys.exit("benchmark did not halt -- does it end with `j .`?")

    v = {k: int(x) for k, x in re.findall(r"^(\w+)=(\d+)$", out, re.M)}
    cyc, ret = v["cycles"], v["retired"]

    print()
    print("predicted board readings")
    print("  cycles   : %d" % cyc)
    print("  retired  : %d" % ret)
    print("  stalls   : %d   (load-use interlock)" % v["stalls"])
    print("  flushes  : %d   (taken branch / jump)" % v["flushes"])
    print("  CPI      : %.4f" % (cyc / ret))
    for code in (2, 3):
        label, mhz = RATES[code]
        print("  at %-8s: %.3f ms, %.2f MIPS" % (label, cyc / (mhz * 1000.0), ret * mhz / cyc))
    print()
    for i in range(4):
        val = v["x%d" % (28 + i)]
        print("  x%-2d      : %d   (0x%08X)" % (28 + i, val, val & 0xFFFFFFFF))
    print("  halt pc  : 0x%08X" % v["haltpc"])

    if not args.no_install:
        shutil.copy(hexp, os.path.join(HERE, "program.hex"))
        print()
        print("installed -> quartus/program.hex   (recompile, then program the board)")


if __name__ == "__main__":
    main()
