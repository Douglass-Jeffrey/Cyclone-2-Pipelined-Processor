#!/usr/bin/env python3
"""Run the as-built Pareto frontier and the defaults on the RTL in Icarus, program by program.

    python experiments/bp_comparison/rtl_frontier.py --snapshot DIR [--jobs 7] [--only N]

Each config gets a copy of DIR/dev with its defines and runs all 19 benchmarks on
tb_pipeline.v: retirement must match rvsim, flushes must match bp_model, and the RTL's
flushes minus the program's jalr count must equal its mispredicts in sweep_per_program.csv.
Results go to data/rtl_frontier.csv (per config) and data/rtl_frontier_per_program.csv;
configs already in rtl_frontier.csv are skipped, so a stopped run resumes.
"""
import argparse
import csv
import os
import shutil
import sys
import time
from multiprocessing import Pool

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import predictors as P  # noqa: E402
import rtl_check as R  # noqa: E402

DATA = os.path.join(HERE, "data")
SUMMARY = os.path.join(DATA, "rtl_frontier.csv")
PER_PROG = os.path.join(DATA, "rtl_frontier_per_program.csv")
HIGHLIGHT = [("tournament", 5, 4, 10)]  # the largest tournament that met 50 MHz


def key(r):
    return (r["family"], int(r["idx_bits"]), int(r["hist_bits"]), int(r["lhist_bits"]))


def plotted():
    """The config behind each point of the as-built Pareto chart (ties included, as the plots pick them)."""
    rows = [r for r in csv.DictReader(open(os.path.join(DATA, "sweep.csv")))
            if r["workload"] == "softmul" and r["rtl_buildable"] == "True"]
    out = set()
    for fam in R.TYPES:
        fr = [r for r in rows if r["family"] == fam]
        bits = [int(r["state_bits"]) for r in fr]
        for k in range((min(bits) - 1).bit_length(), (max(bits) - 1).bit_length() + 1):
            out.add(key(min((r for r in fr if int(r["state_bits"]) <= 2 ** k), key=lambda r: float(r["mpki"]))))
    return out


def configs():
    """{config: why}: the as-built frontier, every plotted point, the defaults and the highlighted build."""
    why = {}
    for r in csv.DictReader(open(os.path.join(DATA, "pareto.csv"))):
        if r["workload"] == "softmul":
            why[key(r)] = ["frontier"]
    for c in plotted():
        why.setdefault(c, []).append("plotted")
    for fam, c in P.DEFAULTS.items():
        why.setdefault((fam,) + c, []).append("default")
    for c in HIGHLIGHT:
        why.setdefault(c, []).append("highlight")
    return {c: "+".join(w) for c, w in why.items()}


def sweep_rows(cfgs):
    """(config, program) -> the sweep's as-built row, for these configs."""
    out = {}
    for r in csv.DictReader(open(os.path.join(DATA, "sweep_per_program.csv"))):
        if r["workload"] == "softmul" and r["family"] in R.TYPES and key(r) in cfgs:
            out[key(r) + (r["program"],)] = r
    return out


def run_one(args):
    """All 19 benchmarks on one config: (config, meta_w, [(program, instrs, stalls, flushes, error)], seconds)."""
    snapshot, (fam, i, h, l) = args
    t0 = time.time()
    harness = R.setup(snapshot)
    sys.path.insert(0, os.path.join(R.ROOT, "benchmarks"))
    import build as bench
    name = "%s_%d_%d_%d" % (fam, i, h, l)
    dev = os.path.join(snapshot, "frontier", "dev_" + name)
    meta_w = R.make_dev(os.path.join(snapshot, "dev"), dev, fam, i, h, l)
    dev = dev.replace("\\", "/")
    run_dir = os.path.join(snapshot, "frontier", "run_" + name)
    shutil.rmtree(run_dir, ignore_errors=True)
    os.makedirs(run_dir)
    vvp = run_dir + "/tb_pipeline.vvp"
    r = harness.compile_tb(dev, vvp, harness.TB_PIPELINE, extra=[harness.SRAM_MODEL])
    if r.returncode:
        return (fam, i, h, l), meta_w, [("compile", 0, 0, 0, (r.stdout + r.stderr)[:300])], time.time() - t0
    progs = []
    for n in bench.BENCHES:
        words = [int(w, 16) for w in open(os.path.join(bench.OUT, n + ".hex")).read().split()]
        folder = run_dir + "/" + n
        os.makedirs(folder)
        with open(folder + "/program.hex", "w") as f:
            f.writelines("%08x\n" % w for w in words)
        errors, k, stalls, flushes = harness.check_against_ref(vvp, words, folder, max_steps=bench.MAX_STEPS,
                                                               dev_dir=dev)
        progs.append((n, k, stalls, flushes, " | ".join(e.replace("\n", " ")[:160] for e in errors[:2])))
    if not any(p[4] for p in progs):            # keep a failing run's files to debug
        shutil.rmtree(run_dir, ignore_errors=True)
        shutil.rmtree(dev, ignore_errors=True)
    return (fam, i, h, l), meta_w, progs, time.time() - t0


def append(path, header, rows):
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(header)
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True, help="a clean copy holding dev/ and verif/")
    ap.add_argument("--jobs", type=int, default=7)
    ap.add_argument("--only", type=int, help="run just the first N remaining configs (for timing)")
    a = ap.parse_args()
    why = configs()
    done = {key(r) for r in csv.DictReader(open(SUMMARY))} if os.path.exists(SUMMARY) else set()
    todo = [c for c in sorted(why) if c not in done][:a.only]
    exp = sweep_rows(set(why))
    jalr = {}
    print("%d configs, %d done, running %d on %d workers" % (len(why), len(done), len(todo), a.jobs), flush=True)
    t0 = time.time()
    with Pool(a.jobs) as pool:
        for k, (c, meta_w, progs, secs) in enumerate(pool.imap_unordered(run_one, [(a.snapshot, c) for c in todo])):
            rows, ok, rtl_mp, sw_mp = [], True, 0, 0
            for n, instrs, stalls, flushes, err in progs:
                if n == "compile":
                    ok = False
                    rows.append(list(c) + [meta_w, n, 0, 0, 0, 0, 0, "", False, err])
                    continue
                if n not in jalr:
                    jalr[n] = int(np.load(os.path.join(DATA, "traces", n + ".npz"))["jalr"])
                mp, want = flushes - jalr[n], int(exp[c + (n,)]["mispredicts"])
                match = not err and mp == want
                ok &= match
                rtl_mp, sw_mp = rtl_mp + mp, sw_mp + want
                rows.append(list(c) + [meta_w, n, instrs, stalls, flushes, jalr[n], mp, want, match, err])
            append(PER_PROG, ["family", "idx_bits", "hist_bits", "lhist_bits", "meta_w", "program", "instrs",
                              "load_use_stalls", "rtl_flushes", "jalr", "rtl_mispredicts", "sweep_mispredicts",
                              "match", "error"], rows)
            append(SUMMARY, ["family", "idx_bits", "hist_bits", "lhist_bits", "state_bits", "meta_w", "why",
                             "programs", "rtl_mispredicts", "sweep_mispredicts", "match", "seconds"],
                   [list(c) + [exp[c + ("coremark",)]["state_bits"], meta_w, why[c], len(rows), rtl_mp, sw_mp, ok,
                               "%.0f" % secs]])
            el = time.time() - t0
            print("%-4s %-26s %7d vs %7d  %4.0fs   [%d/%d, %.0f min elapsed, ~%.0f min left]"
                  % ("ok" if ok else "FAIL", "%s:%d:%d:%d" % c, rtl_mp, sw_mp, secs, k + 1, len(todo), el / 60,
                     el / (k + 1) * (len(todo) - k - 1) / 60), flush=True)


if __name__ == "__main__":
    main()
