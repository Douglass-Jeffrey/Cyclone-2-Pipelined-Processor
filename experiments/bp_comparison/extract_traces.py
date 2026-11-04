#!/usr/bin/env python3
"""Run each benchmark once in rvsim and cache its conditional-branch stream.

    python experiments/bp_comparison/extract_traces.py

Writes data/traces/<program>.npz, one entry per executed conditional branch:
pc, taken, adjacent (right behind another branch, as bp_model.events defines it),
backward (negative offset, for the static BTFN baseline), lib (inside a libgcc
multiply/divide routine) and fn (index into the function names), plus the
program's instruction and jalr counts with and without those routines.
"""
import bisect
import glob
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "verif", "tools"))
import bp_model  # noqa: E402
import rvsim  # noqa: E402

OUT = os.path.join(ROOT, "benchmarks", "out")
TRACES = os.path.join(HERE, "data", "traces")
NM = "riscv-none-elf-nm"
TOOLCHAIN = "/c/xpack-riscv-none-elf-gcc/xpack-riscv-none-elf-gcc-15.2.0-1/bin"
# the RV32I soft multiply/divide routines that an M extension replaces
LIBGCC_MULDIV = {"__mulsi3", "__muldi3", "__divsi3", "__udivsi3", "__hidden___udivsi3",
                 "__modsi3", "__umodsi3"}
MAX_STEPS = 6_000_000


def functions(elf):
    """Text symbols sorted by address: (addrs, names)."""
    env = dict(os.environ)
    env["PATH"] = env.get("PATH", "") + os.pathsep + TOOLCHAIN.replace("/c/", "C:/")
    out = subprocess.run([NM, "-n", elf], capture_output=True, text=True, env=env, check=True).stdout
    syms = [(int(a, 16), n) for a, t, n in (l.split() for l in out.splitlines() if len(l.split()) == 3)
            if t in "tT"]
    return [a for a, _ in syms], [n for _, n in syms]


def extract(prog):
    addrs, names = functions(os.path.join(OUT, prog, "pass2.elf"))
    fn_of = lambda pc: bisect.bisect_right(addrs, pc) - 1
    ref = rvsim.Ref([int(w, 16) for w in open(os.path.join(OUT, prog + ".hex")).read().split()])
    ref.run(MAX_STEPS)

    pc_l, tk, adj, back, fn = [], [], [], [], []
    instrs = instrs_lib = jalr = jalr_lib = 0
    prev_br, k = False, 0
    for pc, instr, *_x in ref.trace:
        op = instr & 0x7F
        f = fn_of(pc)
        in_lib = f >= 0 and names[f] in LIBGCC_MULDIV
        instrs += 1
        instrs_lib += in_lib
        if op == 0x67:
            jalr += 1
            jalr_lib += in_lib
        if op == 0x63:
            pc_l.append(pc)
            tk.append(ref.branch_taken[k])
            adj.append(prev_br)
            back.append(instr >> 31)
            fn.append(f)
            k += 1
        prev_br = op == 0x63

    # same stream bp_model checks the RTL against
    br, j = bp_model.events(ref)
    assert j == jalr and br == list(zip(pc_l, tk, adj)), prog

    fn = np.array(fn, dtype=np.int32)
    lib_ids = np.array([n in LIBGCC_MULDIV for n in names] + [False], dtype=bool)
    np.savez_compressed(
        os.path.join(TRACES, prog + ".npz"),
        pc=np.array(pc_l, dtype=np.uint32), taken=np.array(tk, dtype=np.uint8),
        adjacent=np.array(adj, dtype=np.uint8), backward=np.array(back, dtype=np.uint8),
        lib=lib_ids[fn].astype(np.uint8), fn=fn,
        instrs=instrs, instrs_lib=instrs_lib, jalr=jalr, jalr_lib=jalr_lib)
    with open(os.path.join(TRACES, prog + ".fn.json"), "w") as f:
        json.dump(names, f)
    return prog, instrs, len(pc_l), int(sum(tk)), instrs_lib, int(lib_ids[fn].sum())


def main():
    os.makedirs(TRACES, exist_ok=True)
    progs = sorted(os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(OUT, "*.hex")))
    if not progs:
        sys.exit("no benchmarks: run python benchmarks/build.py first")
    from multiprocessing import Pool
    with Pool() as pool:
        rows = pool.map(extract, progs)
    with open(os.path.join(HERE, "data", "programs.csv"), "w") as f:
        f.write("program,instrs,branches,taken,instrs_in_libgcc_muldiv,branches_in_libgcc_muldiv\n")
        for r in rows:
            f.write(",".join(map(str, r)) + "\n")
            print("%-16s %8d instrs %7d branches (%5.1f%% taken), libgcc mul/div: %4.1f%% of instrs, %4.1f%% of branches"
                  % (r[0], r[1], r[2], 100.0 * r[3] / r[2], 100.0 * r[4] / r[1], 100.0 * r[5] / r[2]))


if __name__ == "__main__":
    main()
