#!/usr/bin/env python3
"""Mispredicts of the five built (default-size) predictors, split by where the
branch is: libgcc multiply/divide routines vs. the program's own code.

    python experiments/bp_comparison/breakdown.py     (after extract_traces.py)

Writes data/breakdown.csv (totals) and data/breakdown_functions.csv (per function).
"""
import csv
import glob
import json
import os
import sys
from collections import Counter

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import predictors as P  # noqa: E402


def main():
    tot = {f: Counter() for f in P.DEFAULTS}
    per_fn = Counter()
    for path in sorted(glob.glob(os.path.join(HERE, "data", "traces", "*.npz"))):
        prog = os.path.splitext(os.path.basename(path))[0]
        d = np.load(path)
        names = json.load(open(path[:-4] + ".fn.json"))
        br = list(zip(d["pc"].tolist(), d["taken"].tolist(), d["adjacent"].tolist()))
        lib, fn = d["lib"].tolist(), d["fn"].tolist()
        for fam, c in P.DEFAULTS.items():
            p = P.build(fam, *c)
            for k, (pc, t, a) in enumerate(br):
                miss = p.predict(pc, a) != t
                p.update(pc, t, miss)
                if miss:
                    tot[fam]["total"] += 1
                    tot[fam]["lib"] += lib[k]
                    per_fn[(fam, prog, names[fn[k]] if fn[k] >= 0 else "?")] += 1
    with open(os.path.join(HERE, "data", "breakdown.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["family", "total", "lib"])
        for fam in P.DEFAULTS:
            w.writerow([fam, tot[fam]["total"], tot[fam]["lib"]])
            print("%-10s %7d mispredicts, %5.1f%% in libgcc mul/div" % (fam, tot[fam]["total"],
                                                                       100.0 * tot[fam]["lib"] / tot[fam]["total"]))
    with open(os.path.join(HERE, "data", "breakdown_functions.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["family", "program", "function", "mispredicts"])
        for (fam, prog, fn), m in sorted(per_fn.items()):
            w.writerow([fam, prog, fn, m])


if __name__ == "__main__":
    main()
