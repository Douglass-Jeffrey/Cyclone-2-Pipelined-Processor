#!/usr/bin/env python3
"""Check that the models the sweep uses are exact for the RTL at non-default sizes.

    python experiments/bp_comparison/rtl_check.py --snapshot DIR trace
    python experiments/bp_comparison/rtl_check.py --snapshot DIR bench FAMILY:IDX:HIST:LHIST ...

DIR holds dev/ and verif/ (e.g. `git archive HEAD dev verif | tar -x -C DIR`), so
other work in the tree can't leak in.  trace: tb_bp_trace (every prediction of a
3,000-branch stream vs bp_model) at the sizes in TRACE_CFGS.  bench: a copy of
dev/ with those defines (BP_META_W raised if the meta needs it) runs all 19
benchmarks; each must retire like rvsim and flush exactly as bp_model predicts.
Results are appended to data/rtl_checks.csv.
"""
import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import predictors as P  # noqa: E402

TYPES = {"bimodal": "BP_BIMODAL", "corr": "BP_CORR", "gshare": "BP_GSHARE", "local": "BP_LOCAL",
         "tournament": "BP_TOURNAMENT"}
# (family, IDX, HIST, LHIST): small, skewed and large-history shapes per predictor
TRACE_CFGS = [("bimodal", 2, 0, 0), ("bimodal", 8, 0, 0),
              ("corr", 2, 6, 0), ("corr", 6, 2, 0), ("corr", 3, 3, 0),
              ("gshare", 1, 7, 0), ("gshare", 6, 2, 0), ("gshare", 2, 5, 0),
              ("local", 1, 0, 10), ("local", 6, 0, 2), ("local", 3, 0, 5),
              ("tournament", 2, 6, 5), ("tournament", 6, 2, 2), ("tournament", 3, 3, 7)]


def setup(snapshot):
    sys.path.insert(0, os.path.join(snapshot, "verif", "tools"))
    sys.path.insert(0, os.path.join(snapshot, "verif"))
    import harness
    tb = os.path.join(snapshot, "verif", "tb").replace("\\", "/")
    harness.TB_DIR, harness.TB_PIPELINE, harness.SRAM_MODEL = tb, tb + "/tb_pipeline.v", tb + "/sram_model.v"
    return harness


def record(rows):
    path = os.path.join(HERE, "data", "rtl_checks.csv")
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["check", "family", "idx_bits", "hist_bits", "lhist_bits", "meta_w", "passed", "detail"])
        w.writerows(rows)


def trace_checks(snapshot):
    harness = setup(snapshot)
    import bp_model
    dev = os.path.join(snapshot, "dev").replace("\\", "/")
    cfg = bp_model.rtl_config(dev + "/defines.vh")
    work = os.path.join(snapshot, "trace_runs")
    rows = []
    for fam, i, h, l in TRACE_CFGS:
        name = "%s_%d_%d_%d" % (fam, i, h, l)
        folder = os.path.join(work, name)
        os.makedirs(folder, exist_ok=True)
        sizes = {"IDX_BITS": i, "HIST_BITS": max(h, 2), "LHIST_BITS": max(l, 2)}
        model = bp_model.RTL_MODELS[TYPES[fam]]({"BP_" + k: v for k, v in sizes.items()})
        with open(os.path.join(folder, "trace.hex"), "w") as f:
            f.writelines("%08x\n" % w for w in bp_model.unit_trace(model, seed=1))
        vvp = os.path.join(folder, "tb.vvp")
        r = harness.compile_tb(dev, vvp, harness.TB_DIR + "/tb_bp_trace.v", "tb_bp_trace", (),
                               dict(sizes, TYPE=cfg[TYPES[fam]]))
        out = r.stdout + r.stderr
        if r.returncode == 0:
            out += subprocess.run(["vvp", vvp], cwd=folder, capture_output=True, text=True).stdout
        ok = r.returncode == 0 and "PASSED" in out and "FAIL" not in out
        last = [x for x in out.splitlines() if x.startswith(("BP TRACE", "FAIL")) or "error" in x.lower()]
        rows.append(["tb_bp_trace", fam, i, h, l, 32, ok, (last or ["?"])[0]])
        print("%-5s %-34s %s" % ("ok" if ok else "FAIL", name, (last or ["?"])[0]), flush=True)
    record(rows)


def bench_one(args):
    snapshot, (fam, i, h, l) = args
    harness = setup(snapshot)
    sys.path.insert(0, os.path.join(ROOT, "benchmarks"))
    import build as bench
    meta = P.meta_bits(fam, i, h, l)
    meta_w = max(32, meta)
    name = "%s_%d_%d_%d" % (fam, i, h, l)
    dev = os.path.join(snapshot, "dev_" + name)
    if os.path.isdir(dev):
        shutil.rmtree(dev)
    shutil.copytree(os.path.join(snapshot, "dev"), dev)
    p = os.path.join(dev, "defines.vh")
    s = open(p).read()
    for k, v in (("BP_TYPE", "`" + TYPES[fam]), ("BP_IDX_BITS", i), ("BP_HIST_BITS", max(h, 2)),
                 ("BP_LHIST_BITS", max(l, 2)), ("BP_META_W", meta_w)):
        s, n = re.subn(r"(`define\s+%s\s+)\S+" % k, r"\g<1>%s" % v, s)
        assert n == 1, k
    open(p, "w").write(s)
    dev = dev.replace("\\", "/")
    run_dir = os.path.join(snapshot, "bench_runs", name)
    if os.path.isdir(run_dir):
        shutil.rmtree(run_dir)
    os.makedirs(run_dir)
    vvp = run_dir + "/tb_pipeline.vvp"
    r = harness.compile_tb(dev, vvp, harness.TB_PIPELINE, extra=[harness.SRAM_MODEL])
    if r.returncode:
        return ["bench_flushes", fam, i, h, l, meta_w, False, "compile: " + (r.stdout + r.stderr)[:200]]
    bad, total = [], 0
    for n in bench.BENCHES:
        words = [int(w, 16) for w in open(os.path.join(bench.OUT, n + ".hex")).read().split()]
        folder = run_dir + "/" + n
        os.makedirs(folder)
        with open(folder + "/program.hex", "w") as f:
            f.writelines("%08x\n" % w for w in words)
        errors, k, stalls, flushes = harness.check_against_ref(vvp, words, folder, max_steps=bench.MAX_STEPS,
                                                               dev_dir=dev)
        total += flushes or 0
        if errors:
            bad.append("%s: %s" % (n, errors[0][:120]))
    detail = "19 programs, %d flushes, RTL == model" % total if not bad else "; ".join(bad[:3])
    print("%-5s %-34s meta %d/%d  %s" % ("ok" if not bad else "FAIL", name, meta, meta_w, detail), flush=True)
    return ["bench_flushes", fam, i, h, l, meta_w, not bad, detail]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("what", choices=["trace", "bench"])
    ap.add_argument("cfgs", nargs="*", help="FAMILY:IDX:HIST:LHIST")
    ap.add_argument("--jobs", type=int, default=3)
    a = ap.parse_args()
    if a.what == "trace":
        trace_checks(a.snapshot)
    else:
        cfgs = [(c.split(":")[0],) + tuple(int(x) for x in c.split(":")[1:]) for c in a.cfgs]
        with Pool(a.jobs) as pool:
            record(pool.map(bench_one, [(a.snapshot, c) for c in cfgs]))


if __name__ == "__main__":
    main()
