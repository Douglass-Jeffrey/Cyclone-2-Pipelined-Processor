#!/usr/bin/env python3
"""Replay the cached branch streams through every config in predictors.grid().

    python experiments/bp_comparison/sweep.py           (after extract_traces.py)

Two workloads per program: "softmul" (as built: RV32I, libgcc multiply/divide)
and "hwmul" (the branches inside those routines removed, and their instructions
dropped from the count, approximating an M extension).  Each program starts
from a fresh (reset) predictor, as on the board.

Writes data/sweep_per_program.csv (config x workload x program) and
data/sweep.csv (config x workload, totals and the per-program mean).
"""
import csv
import glob
import os
import sys
import time
from multiprocessing import Pool

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import predictors as P  # noqa: E402

TRACES = os.path.join(HERE, "data", "traces")
WORKLOADS = ("softmul", "hwmul")
_streams = None     # per worker: {(workload, program): (branch list, instrs)}


def load_streams():
    s = {}
    for path in sorted(glob.glob(os.path.join(TRACES, "*.npz"))):
        prog = os.path.splitext(os.path.basename(path))[0]
        d = np.load(path)
        keep = d["lib"] == 0
        for wl, mask, instrs in (("softmul", np.ones_like(keep), int(d["instrs"])),
                                 ("hwmul", keep, int(d["instrs"]) - int(d["instrs_lib"]))):
            br = list(zip(d["pc"][mask].tolist(), d["taken"][mask].tolist(), d["adjacent"][mask].tolist()))
            s[(wl, prog)] = (br, instrs, d["backward"][mask])
    return s


def _init():
    global _streams
    _streams = load_streams()


def run_config(cfg):
    rows = []
    for (wl, prog), (br, instrs, _b) in _streams.items():
        rows.append((cfg, wl, prog, len(br), instrs, P.B.mispredicts(P.build(*cfg), br)))
    return rows


def baselines(streams):
    """Static predictors (0 bits): always not-taken, and backward-taken/forward-not-taken."""
    rows = []
    for (wl, prog), (br, instrs, back) in streams.items():
        taken = np.array([t for _, t, _ in br], dtype=bool)
        rows.append((("static_not_taken", 0, 0, 0), wl, prog, len(br), instrs, int(taken.sum())))
        rows.append((("static_btfn", 0, 0, 0), wl, prog, len(br), instrs, int((taken != back.astype(bool)).sum())))
    return rows


def write(rows):
    cols = ["family", "idx_bits", "hist_bits", "lhist_bits", "state_bits", "meta_bits",
            "rtl_buildable", "meta_fits_32", "is_default"]

    def cfg_cols(cfg):
        fam, i, h, l = cfg
        if fam.startswith("static"):
            return [fam, "", "", "", 0, 0, False, True, False]
        m = P.meta_bits(fam, i, h, l)
        return [fam, i, h, l, P.build(*cfg).bits, m, P.rtl_buildable(fam, i, h, l),
                m <= P.META_W, P.DEFAULTS.get(fam) == (i, h, l)]

    rows.sort(key=lambda r: (r[0][0], r[0][1:], r[1], r[2]))
    with open(os.path.join(HERE, "data", "sweep_per_program.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols + ["workload", "program", "branches", "instrs", "mispredicts", "mpki", "mispredict_rate"])
        for cfg, wl, prog, nb, ni, m in rows:
            w.writerow(cfg_cols(cfg) + [wl, prog, nb, ni, m, "%.4f" % (1000.0 * m / ni),
                                        "%.5f" % (m / nb if nb else 0)])
    agg = {}
    for cfg, wl, prog, nb, ni, m in rows:
        a = agg.setdefault((cfg, wl), [0, 0, 0, []])
        a[0] += nb; a[1] += ni; a[2] += m
        a[3].append(1000.0 * m / ni)
    with open(os.path.join(HERE, "data", "sweep.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols + ["workload", "branches", "instrs", "mispredicts", "mpki", "mean_program_mpki",
                           "mispredict_rate"])
        for (cfg, wl), (nb, ni, m, per) in sorted(agg.items(), key=lambda kv: (kv[0][0][0], kv[0][0][1:], kv[0][1])):
            w.writerow(cfg_cols(cfg) + [wl, nb, ni, m, "%.4f" % (1000.0 * m / ni),
                                        "%.4f" % (sum(per) / len(per)), "%.5f" % (m / nb)])


def read_rows(families):
    """data/sweep_per_program.csv's rows for every family not being rerun."""
    rows = []
    with open(os.path.join(HERE, "data", "sweep_per_program.csv")) as f:
        for r in csv.DictReader(f):
            if r["family"] in families:
                continue
            c = (r["family"],) + tuple(int(r[k] or 0) for k in ("idx_bits", "hist_bits", "lhist_bits"))
            rows.append((c, r["workload"], r["program"], int(r["branches"]), int(r["instrs"]),
                         int(r["mispredicts"])))
    return rows


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--families", nargs="*", help="rerun only these, keeping the other rows")
    a = ap.parse_args()
    cfgs = [c for c in P.grid() if not a.families or c[0] in a.families]
    cfgs.sort(key=lambda c: (c[0] != "tournament", -P.build(*c).bits))   # slow ones first
    t0 = time.time()
    rows = read_rows(set(a.families)) if a.families else baselines(load_streams())
    with Pool(initializer=_init) as pool:
        for k, r in enumerate(pool.imap_unordered(run_config, cfgs), 1):
            rows += r
            if k % 50 == 0 or k == len(cfgs):
                print("%4d / %d configs  (%.0f s)" % (k, len(cfgs), time.time() - t0), flush=True)
    write(rows)
    print("wrote data/sweep.csv and data/sweep_per_program.csv")


if __name__ == "__main__":
    main()
