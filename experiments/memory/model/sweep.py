"""Miss counts for every cache organization on every program -> data/dcache_counts.csv, data/icache_counts.csv

    python experiments/memory/model/traces.py      (once: the traces)
    python experiments/memory/model/sweep.py
"""
import csv
import itertools
import os
from multiprocessing import Pool

import cachesim
import traces

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
D_ORGS = [dict(size=s, line=l, ways=w, wv=0)
          for s, l, w in itertools.product((8192, 16384, 32768), (16, 32, 64), (1, 2, 4))]
D_ORGS += [dict(size=16384, line=l, ways=w, wv=1) for l, w in itertools.product((16, 32, 64), (1, 2))]
I_ORGS = [dict(size=s, line=l, ways=w) for s, l, w in itertools.product((8192, 16384), (16, 32, 64), (1, 2))]


def d_job(job):
    n, o = job
    data, _, _ = traces.load(n)
    r = cachesim.dcache(data.tolist(), o["size"], o["line"], o["ways"], bool(o["wv"]))
    return dict(program=n, **o, **r)


def i_job(job):
    n, o = job
    _, fetch, _ = traces.load(n)
    return dict(program=n, **o, miss=cachesim.icache(fetch.tolist(), o["size"], o["line"], o["ways"]))


def write(path, rows):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)


if __name__ == "__main__":
    os.makedirs(DATA, exist_ok=True)
    with Pool(6) as p:
        d = p.map(d_job, [(n, o) for o in D_ORGS for n in traces.PROGS], chunksize=4)
        write(os.path.join(DATA, "dcache_counts.csv"), d)
        i = p.map(i_job, [(n, o) for o in I_ORGS for n in traces.PROGS], chunksize=4)
        write(os.path.join(DATA, "icache_counts.csv"), i)
    print("dcache rows %d, icache rows %d" % (len(d), len(i)))
