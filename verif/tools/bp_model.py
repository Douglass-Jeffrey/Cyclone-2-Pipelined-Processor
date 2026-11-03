#!/usr/bin/env python3
"""Branch-predictor models: the reference for the RTL's flush count.

rvsim says what a program computes; this says how many times the front end is
redirected while computing it.  A predictor bug never gives a wrong result (EX
fixes every bad guess), so the count is the only thing that catches one:
harness.check_against_ref requires the RTL's flushes to equal flushes() here.

    python verif/tools/bp_model.py                    compare predictors on benchmarks/out/*.hex
    python verif/tools/bp_model.py a.S b.hex          ... on these programs

A redirect costs one cycle: a conditional branch predicted wrong in ID, or any
jalr (resolved in EX, never predicted).  jal is taken in ID for free.

Timing copied from the RTL:
  - lookup in ID, training at the end of EX.  A branch right behind another (in
    ID while the first is in EX) reads the table BEFORE the first one's update
    lands, unless the first mispredicted: then it is refetched after the update.
  - Correlating (corr_bp.v) shifts its global history at training, so that same
    second branch also looks up without the first one's outcome.  Local
    (local_bp.v) does the same with each slot's history: a Table with a shift
    for its step.  Gshare and Tournament shift global history speculatively in
    ID and repair it on a mispredict, so every lookup sees every earlier outcome.

Only the predictor dev/defines.vh selects (RTL_MODELS) is checked against the
RTL.  The rest are for trying designs before building them.
"""
import glob
import os
import random
import re
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(TOOLS))
DEFINES = os.path.join(ROOT, "dev", "defines.vh")
sys.path.insert(0, TOOLS)
import rvsim  # noqa: E402


# ---- the program's side: what the predictor sees ------------------------------
def events(ref):
    """From a finished rvsim.Ref: conditional branches as (pc, taken, right behind
    another branch), and the jalr count."""
    br, jalr, prev, k = [], 0, False, 0
    for pc, instr, *_x in ref.trace:
        op = instr & 0x7F
        if op == 0x63:
            br.append((pc, ref.branch_taken[k], prev))
            k += 1
        jalr += op == 0x67
        prev = op == 0x63
    return br, jalr


def mispredicts(pred, br):
    n = 0
    for pc, taken, adjacent in br:
        miss = pred.predict(pc, adjacent) != taken
        n += miss
        pred.update(pc, taken, miss)
    return n


def flushes(ref, pred=None):
    """Front-end redirects the RTL must report for this run (default: the RTL's predictor)."""
    br, jalr = events(ref)
    return mispredicts(pred or rtl_predictor(), br) + jalr


# ---- which predictor the RTL has --------------------------------------------
def rtl_config(path=DEFINES):
    """The BP_* defines, with `NAME references resolved."""
    raw = dict(re.findall(r"^\s*`define\s+(BP_\w+)\s+(`?\w+)", open(path).read(), re.M))

    def val(k):
        v = raw[k]
        return val(v[1:]) if v.startswith("`") else int(v, 0)
    return {k: val(k) for k in raw}


def rtl_type(path=DEFINES):
    """The predictor define BP_TYPE names, e.g. "BP_CORR"."""
    m = re.search(r"^\s*`define\s+BP_TYPE\s+`(\w+)", open(path).read(), re.M)
    if not m:
        raise ValueError("%s: BP_TYPE must name a predictor define, e.g. `BP_BIMODAL" % path)
    return m.group(1)


# each predictor branch_predictor.v can build, by its define, and its model
RTL_MODELS = {
    "BP_BIMODAL": lambda c: Bimodal(1 << c["BP_IDX_BITS"]),
    "BP_CORR":    lambda c: Correlating(c["BP_HIST_BITS"], 1 << c["BP_IDX_BITS"]),
    "BP_GSHARE":  lambda c: Gshare(c["BP_HIST_BITS"], 1 << c["BP_IDX_BITS"]),
    "BP_LOCAL":   lambda c: Local(1 << c["BP_IDX_BITS"], c["BP_LHIST_BITS"]),
    "BP_TOURNAMENT": lambda c: Tournament(Local(1 << c["BP_IDX_BITS"], c["BP_LHIST_BITS"]),
                                          Gshare(c["BP_HIST_BITS"], 1 << c["BP_IDX_BITS"]),
                                          1 << c["BP_IDX_BITS"]),
}


def rtl_predictor(path=DEFINES):
    """A fresh model of the predictor the defines.vh at path selects."""
    t = rtl_type(path)
    if t not in RTL_MODELS:
        raise ValueError("bp_model.py has no model for %s" % t)
    return RTL_MODELS[t](rtl_config(path))


# ---- the predictors ------------------------------------------------------------
def sat(c, taken):
    return min(c + 1, 3) if taken else max(c - 1, 0)


class Table:
    """2-bit counters (00/01 not taken, 10/11 taken), written one branch late when
    the next branch is right behind and this one was predicted right.  step is
    what a write does to an entry (a history table shifts the outcome in)."""
    def __init__(self, n, init=1, step=sat):
        self.c = [init] * n
        self.pending = None
        self.step = step

    def read(self, i, adjacent):
        if not adjacent:
            self.land()
        return self.c[i]

    def write(self, i, taken, redirect):
        self.land()
        self.pending = (i, taken)
        if redirect:
            self.land()

    def land(self):
        if self.pending:
            i, t = self.pending
            self.c[i] = self.step(self.c[i], t)
            self.pending = None


class Bimodal:
    """What the RTL has: one counter per pc[k+1:2]."""
    def __init__(self, n):
        self.n, self.t = n, Table(n)
        self.bits = 2 * n

    def predict(self, pc, adjacent):
        self.i = (pc >> 2) % self.n
        return self.t.read(self.i, adjacent) >= 2

    def update(self, pc, taken, redirect):
        self.t.write(self.i, taken, redirect)


class Correlating:
    """(m,2) as corr_bp.v builds it: m bits of global history pick one of 2^m
    counters for each pc slot.  History shifts at training, so a branch right
    behind another looks up without that one's outcome unless it mispredicted;
    training writes the counter the lookup read (corr_bp.v's meta)."""
    def __init__(self, m, pc_entries):
        self.m, self.pe = m, pc_entries
        self.t, self.ghr, self.prev, self.redirect = Table(pc_entries << m), 0, 0, True
        self.bits = 2 * (pc_entries << m) + m

    def predict(self, pc, adjacent):
        h = self.prev if adjacent and not self.redirect else self.ghr
        self.i = (((pc >> 2) % self.pe) << self.m) | h
        return self.t.read(self.i, adjacent) >= 2

    def update(self, pc, taken, redirect):
        self.t.write(self.i, taken, redirect)
        self.prev, self.redirect = self.ghr, redirect
        self.ghr = ((self.ghr << 1) | taken) & ((1 << self.m) - 1)


class Gshare:
    """gshare_bp.v: pc XOR m bits of global history index one table as big as
    Correlating(m, pc_entries)'s, the history XORed into the top m index bits.
    The history is speculative (repaired on a mispredict), so it is always every
    earlier outcome; only the table lands late."""
    def __init__(self, m, pc_entries):
        self.m, self.k = m, pc_entries.bit_length() - 1
        self.n = pc_entries << m
        self.t, self.ghr = Table(self.n), 0
        self.bits = 2 * self.n + m

    def predict(self, pc, adjacent):
        self.i = ((pc >> 2) ^ (self.ghr << self.k)) % self.n
        return self.t.read(self.i, adjacent) >= 2

    def update(self, pc, taken, redirect):
        self.t.write(self.i, taken, redirect)
        self.ghr = ((self.ghr << 1) | taken) & ((1 << self.m) - 1)


class Local:
    """local_bp.v: each of nh pc slots keeps its last l outcomes, which pick one of
    2^l counters every slot shares.  The slot history shifts at training, so it
    lands late like the counters."""
    def __init__(self, nh, l):
        mask = (1 << l) - 1
        self.nh = nh
        self.h = Table(nh, init=0, step=lambda v, t: ((v << 1) | t) & mask)
        self.t = Table(1 << l)
        self.bits = nh * l + 2 * (1 << l)

    def predict(self, pc, adjacent):
        self.hi = (pc >> 2) % self.nh
        self.i = self.h.read(self.hi, adjacent)
        return self.t.read(self.i, adjacent) >= 2

    def update(self, pc, taken, redirect):
        self.t.write(self.i, taken, redirect)
        self.h.write(self.hi, taken, redirect)


class Tournament:
    """Two predictors and a pc-indexed chooser, trained only when they disagree
    (tournament_bp.v: a = Local, b = Gshare, starting weakly on b)."""
    def __init__(self, a, b, nch):
        self.a, self.b, self.nch = a, b, nch
        self.ch = Table(nch, init=2)            # >= 2 picks b
        self.bits = a.bits + b.bits + 2 * nch

    def predict(self, pc, adjacent):
        self.pa = self.a.predict(pc, adjacent)
        self.pb = self.b.predict(pc, adjacent)
        self.ci = (pc >> 2) % self.nch
        return self.pb if self.ch.read(self.ci, adjacent) >= 2 else self.pa

    def update(self, pc, taken, redirect):
        self.a.update(pc, taken, redirect)
        self.b.update(pc, taken, redirect)
        if self.pa != self.pb:
            self.ch.write(self.ci, self.pb == taken, redirect)
        else:
            self.ch.land()


PREDICTORS = [
    ("bimodal32", lambda: Bimodal(32)),
    ("bimodal256", lambda: Bimodal(256)),
    ("corr(4,32)", lambda: Correlating(4, 32)),
    ("gsh(4,32)", lambda: Gshare(4, 32)),
    ("loc(32,8)", lambda: Local(32, 8)),
    ("loc(32,10)", lambda: Local(32, 10)),
    ("tourn", lambda: Tournament(Local(32, 8), Gshare(4, 32), 32)),
]


def unit_trace(pred, seed, n=3000):
    """verif/tb/tb_bp_trace.v's trace.hex words: n branches from a few pcs that share
    slots and gshare counters, often back to back or held in ID, each carrying the
    prediction pred (a fresh model sized like the testbench) makes for it."""
    rnd = random.Random(seed)
    # neighbours; 0x440 and 0x600 share 0x400's slot (16- and 128-word strides)
    pcs = [0x400, 0x404, 0x408, 0x440, 0x600, 0x52c]
    count = [0] * len(pcs)
    words, prev_br = [], False
    for b in range(n):
        if b % 500 == 0:                # each pc a loop, an alternator, biased or a coin flip
            kinds = [rnd.choice(["loop", "alt", "bias", "coin"]) for _ in pcs]
            trip = [rnd.randint(2, 6) for _ in pcs]
        gap = 0 if rnd.random() < 0.5 else rnd.randint(1, 3)
        for _ in range(gap):
            words.append((rnd.randint(1, 2) << 30) | 0x800 | (rnd.randrange(64) << 2))
        k = rnd.randrange(len(pcs))
        count[k] += 1
        taken = {"loop": count[k] % trip[k] != 0, "alt": count[k] % 2 == 1,
                 "bias": rnd.random() < 0.85, "coin": rnd.random() < 0.5}[kinds[k]]
        hold = 0 if rnd.random() < 0.85 else rnd.randint(1, 3)
        p = pred.predict(pcs[k], prev_br and gap == 0 and hold == 0)
        pred.update(pcs[k], taken, p != taken)
        words.append((taken << 29) | (p << 28) | (hold << 26) | pcs[k])
        prev_br = True
    return words + [0xFFFFFFFF]


def load(path, tmp):
    if path.lower().endswith(".hex"):
        return [int(w, 16) for w in open(path).read().split()]
    return rvsim.assemble(path, os.path.join(tmp, os.path.splitext(os.path.basename(path))[0] + ".hex"))


def main():
    paths = sys.argv[1:] or sorted(glob.glob(os.path.join(ROOT, "benchmarks", "out", "*.hex")))
    if not paths:
        sys.exit("no programs: build benchmarks/ (python benchmarks/build.py) or name some")
    print("mispredicted conditional branches, %%; the RTL has %s\n" % type(rtl_predictor()).__name__)
    print("%-16s %8s %7s %6s |" % ("program", "instrs", "branch", "jalr") +
          "".join("%11s" % n for n, _ in PREDICTORS))
    tot_i = tot_j = 0
    tot_m = [0] * len(PREDICTORS)
    with tempfile.TemporaryDirectory() as tmp:
        for path in paths:
            ref = rvsim.Ref(load(path, tmp))
            ref.run(6_000_000)
            br, jalr = events(ref)
            n = len(ref.trace)
            tot_i += n
            tot_j += jalr
            line = "%-16s %8d %7d %6d |" % (os.path.splitext(os.path.basename(path))[0], n, len(br), jalr)
            for k, (_, mk) in enumerate(PREDICTORS):
                m = mispredicts(mk(), br)
                tot_m[k] += m
                line += "%10.1f%%" % (100.0 * m / max(len(br), 1))
            print(line, flush=True)
    print("\nredirects per 1000 instructions, all programs: jalr %.1f, mispredicts %s"
          % (1000.0 * tot_j / tot_i, ", ".join("%s %.1f" % (n, 1000.0 * m / tot_i)
                                               for (n, _), m in zip(PREDICTORS, tot_m))))


if __name__ == "__main__":
    main()
