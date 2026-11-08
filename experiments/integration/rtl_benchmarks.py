#!/usr/bin/env python3
"""All 19 benchmarks on the integrated design in Icarus, checked against both studies.

    python experiments/integration/rtl_benchmarks.py --snapshot DIR

DIR is a clean copy of dev/ and verif/ (e.g. git archive HEAD dev quartus verif). Retirement must
match rvsim and flushes bp_model; flushes minus jalr must equal the branch predictor sweep's
mispredicts for the configured tournament on every program. Writes data/rtl_benchmarks.csv.
"""
import argparse
import csv
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BP = os.path.join(os.path.dirname(HERE), "bp_comparison")
sys.path.insert(0, BP)
import rtl_frontier as F  # noqa: E402

CFG = ("tournament", 5, 4, 10)   # as in dev/defines.vh


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True)
    a = ap.parse_args()
    want = {r["program"]: int(r["mispredicts"]) for r in csv.DictReader(open(os.path.join(BP, "data", "sweep_per_program.csv")))
            if r["workload"] == "softmul" and r["family"] == CFG[0] and F.key(r) == CFG}
    _, _, progs, secs = F.run_one((a.snapshot, CFG))
    rows, ok = [], True
    for n, instrs, stalls, flushes, err in progs:
        jalr = int(np.load(os.path.join(BP, "data", "traces", n + ".npz"))["jalr"]) if n in want else 0
        match = not err and n in want and flushes - jalr == want[n]
        ok &= match
        rows.append([n, instrs, stalls, flushes, jalr, flushes - jalr, want.get(n, ""), match, err])
    os.makedirs(os.path.join(HERE, "data"), exist_ok=True)
    with open(os.path.join(HERE, "data", "rtl_benchmarks.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["program", "instrs", "load_use_stalls", "rtl_flushes", "jalr", "rtl_mispredicts",
                    "sweep_mispredicts", "match", "error"])
        w.writerows(rows)
    print("%s: %d programs, %d instrs, flushes %d, mispredicts %d vs sweep %d, %.0f s"
          % ("ALL MATCH" if ok else "MISMATCH", len(rows), sum(r[1] for r in rows), sum(r[3] for r in rows),
             sum(r[5] for r in rows), sum(want.values()), secs))


if __name__ == "__main__":
    main()
