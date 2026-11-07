#!/usr/bin/env python3
"""Join the DE1's 19-benchmark runs of each memory design with their simulations in data/sim/.

    python experiments/memory/harness/board_suite.py

Board runs come from experiments/bp_comparison/board_check.py (original: the bimodal default in
bp_comparison/data/board/; the patched designs: data/board/<design>/). Each is compared with the
tb_mem.v run in data/sim/<tag>_warm.json on every counter both record.
Writes data/board/suite.csv and prints the totals.
"""
import csv
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MEM = os.path.dirname(HERE)
DESIGNS = [  # (design, board runs.csv, sim tag)
    ("original", os.path.join(MEM, "..", "bp_comparison", "data", "board", "runs.csv"), "base"),
    ("new_controller", os.path.join(MEM, "data", "board", "new_controller", "runs.csv"), "rd1wf"),
    ("combined", os.path.join(MEM, "data", "board", "combined", "runs.csv"), "comb123"),
]
FIELDS = [  # (board column, tb_mem key)
    ("cycles", "cycles"), ("retired", "retired"), ("stalls", "stalls"), ("flushes", "flushes"),
    ("x28", "x28"), ("x29", "x29"), ("x30", "x30"), ("x31", "x31"),
    ("dcache_misses", "dmiss"), ("dcache_writebacks", "dwb"), ("icache_misses", "imiss"),
]


def board_rows(path):
    """program -> its first bimodal-default run (later rows are swap-vs-full checks), and those checks."""
    first, extra = {}, []
    for r in csv.DictReader(open(path)):
        if (r["family"], r["idx_bits"], r["hist_bits"], r["lhist_bits"]) != ("bimodal", "5", "0", "0"):
            continue
        if r["program"] in first:
            extra.append(r)
        else:
            first[r["program"]] = r
    return first, extra


def main():
    out, totals = [], []
    for design, path, tag in DESIGNS:
        if not os.path.exists(path):
            print("no board runs yet for", design)
            continue
        sim = json.load(open(os.path.join(MEM, "data", "sim", tag + "_warm.json")))
        runs, extra = board_rows(path)
        n_ok, cyc, flu, busy = 0, 0, 0, 0
        for p, r in runs.items():
            s = sim[p]
            diff = [b for b, k in FIELDS if int(r["board_" + b]) != s[k]]
            ok = not diff and r["match"] == "True"
            n_ok += ok
            cyc, flu, busy = cyc + int(r["board_cycles"]), flu + int(r["board_flushes"]), busy + s["dbusy"]
            out.append([design, p, r["method"]] + [r["board_" + b] for b, _ in FIELDS]
                       + [s["dbusy"], r["match"], " ".join(diff), ok])
        swaps_ok = all(r["match"] == "True" and r["board_cycles"] == runs[r["program"]]["board_cycles"]
                       for r in extra)
        totals.append((design, len(runs), n_ok, cyc, flu, busy, len(extra), swaps_ok))
    with open(os.path.join(MEM, "data", "board", "suite.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["design", "program", "method"] + ["board_" + b for b, _ in FIELDS]
                   + ["sim_dcache_freeze", "board_matches_tb_bench", "differs_from_tb_mem", "all_match"])
        w.writerows(out)
    base = totals[0][3]
    print("%-15s %8s %9s %10s %8s %10s %8s %s" % ("design", "programs", "all match", "cycles", "vs orig",
                                                 "sim freeze", "flushes", "swap-vs-full checks"))
    for d, n, ok, cyc, flu, busy, nx, sx in totals:
        print("%-15s %8d %9d %10d %+7.2f%% %10d %8d %s" % (d, n, ok, cyc, 100.0 * (cyc - base) / base, busy, flu,
                                                          "%d, %s" % (nx, "identical" if sx else "DIFFER") if nx else "-"))


if __name__ == "__main__":
    main()
