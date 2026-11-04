"""Memory traces for the cache model: every data access and instruction fetch.

    python experiments/memory/model/traces.py          extract (skips programs already cached)

Runs each program on verif/tools/rvsim.py, the RV32I reference model, and
records, in program order (the order the in-order pipeline's caches see them):
  data   one uint32 per load/store: byte address (18-bit data region) | store<<20 | width<<21
         (width: 0 byte, 1 halfword, 2 word)
  fetch  the pc of every instruction fetched (18-bit code region)
Cached as build/cache_model_traces/<prog>.npz (build/ is gitignored).
"""
import os
import sys
from array import array
from multiprocessing import Pool

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path[:0] = [os.path.join(ROOT, "verif", "tools"), os.path.join(ROOT, "benchmarks")]
import rvsim  # noqa: E402
import build as B  # noqa: E402

CACHE = os.path.join(ROOT, "build", "cache_model_traces")
MICRO_DIR = os.environ.get("MEM_MICRO_DIR", os.path.join(HERE, "programs"))
MICRO = ["m_stream", "m_copy", "m_chase"]
PROGS = sorted(B.BENCHES) + MICRO
REGION = (1 << 18) - 1          # each cache sees an 18-bit region (README 2.1)


def hexfile(n):
    return os.path.join(MICRO_DIR, n + ".hex") if n in MICRO else os.path.join(B.OUT, n + ".hex")


class TraceRef(rvsim.Ref):
    def __init__(self, words):
        super().__init__(words)
        self.d = array("I")
        self.f = array("I")

    def load(self, addr, f3):
        self.d.append((addr & REGION) | ((f3 & 3) << 21))
        return super().load(addr, f3)

    def store(self, addr, f3, val):
        self.d.append((addr & REGION) | (1 << 20) | ((f3 & 3) << 21))
        super().store(addr, f3, val)

    def step(self):
        self.f.append(self.pc & REGION)
        super().step()


def extract(n):
    out = os.path.join(CACHE, n + ".npz")
    if os.path.exists(out):
        return n, "cached"
    words = [int(w, 16) for w in open(hexfile(n)).read().split()]
    ref = TraceRef(words)
    ref.run(B.MAX_STEPS)
    f = np.frombuffer(ref.f, dtype=np.uint32)
    np.savez_compressed(out, data=np.frombuffer(ref.d, dtype=np.uint32), fetch=f,
                        instrs=np.array([len(ref.trace)]))
    return n, "%d instrs, %d data accesses" % (len(ref.trace), len(ref.d))


def load(n):
    z = np.load(os.path.join(CACHE, n + ".npz"))
    return z["data"], z["fetch"], int(z["instrs"][0])


if __name__ == "__main__":
    os.makedirs(CACHE, exist_ok=True)
    with Pool(6) as p:
        for n, msg in p.imap_unordered(extract, PROGS):
            print("%-15s %s" % (n, msg), flush=True)
