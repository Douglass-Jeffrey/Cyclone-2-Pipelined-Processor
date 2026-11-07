"""The predictor configurations the sweep runs, built from verif/tools/bp_model.py.

Every family except the *_variant ones is exactly what dev/src builds for those
defines (bp_model.RTL_MODELS), so its mispredicts are the RTL's.  The variants
are model-only, to separate one design choice from another.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "verif", "tools"))
import bp_model as B  # noqa: E402

MAX_BITS = 36 * 1024        # model sweep ceiling; the FPGA fits ~5 Kbit (see quartus.csv)
META_W = 32                 # dev/defines.vh BP_META_W


class GshareLow(B.Gshare):
    """Classic gshare: the m history bits XOR the LOW index bits."""
    def predict(self, pc, adjacent):
        self.i = ((pc >> 2) ^ self.ghr) % self.n
        return self.t.read(self.i, adjacent) >= 2


class CorrSpec(B.Correlating):
    """corr's {pc slot, history} index with gshare's speculative history."""
    def predict(self, pc, adjacent):
        self.i = (((pc >> 2) % self.pe) << self.m) | self.ghr
        return self.t.read(self.i, adjacent) >= 2


class GshareLate(B.Gshare):
    """gshare's XOR-top index with corr's history, shifted at training."""
    def __init__(self, m, pc_entries):
        super().__init__(m, pc_entries)
        self.prev, self.redirect = 0, True

    def predict(self, pc, adjacent):
        h = self.prev if adjacent and not self.redirect else self.ghr
        self.i = ((pc >> 2) ^ (h << self.k)) % self.n
        return self.t.read(self.i, adjacent) >= 2

    def update(self, pc, taken, redirect):
        self.prev, self.redirect = self.ghr, redirect
        super().update(pc, taken, redirect)


def build(family, idx=0, hist=0, lhist=0):
    """A fresh model for one config, named by the RTL's defines (BP_IDX_BITS, ...)."""
    pe = 1 << idx
    if family == "bimodal":
        return B.Bimodal(pe)
    if family == "corr":
        return B.Correlating(hist, pe)
    if family == "corr_spec_variant":
        return CorrSpec(hist, pe)
    if family == "gshare":
        return B.Gshare(hist, pe)
    if family == "gshare_late_variant":
        return GshareLate(hist, pe)
    if family == "gshare_low_variant":
        return GshareLow(hist, pe)
    if family == "local":
        return B.Local(pe, lhist)
    if family == "tournament":
        return B.Tournament(B.Local(pe, lhist), B.Gshare(hist, pe), pe)
    raise ValueError(family)


def meta_bits(family, idx, hist, lhist):
    """Width of pred_meta the RTL carries through id_ex for this config."""
    return {"bimodal": idx, "corr": idx + hist, "gshare": idx + 2 * hist, "local": idx + lhist,
            "tournament": 2 + hist + (idx + hist) + lhist + idx}.get(family, 0)


def rtl_buildable(family, idx, hist, lhist):
    """Whether dev/src builds this config as is (history slices need >= 2 bits, and every
    predictor's pc slice pc[IDX_BITS+1:2] needs IDX_BITS >= 1); BP_META_W may need raising."""
    if family.endswith("_variant"):
        return False
    if family in ("corr", "gshare", "tournament") and hist < 2:
        return False
    if family in ("local", "tournament") and lhist < 2:
        return False
    if idx < 1:
        return False
    return True


def grid():
    """Every config the sweep runs: (family, idx, hist, lhist)."""
    cfgs = [("bimodal", i, 0, 0) for i in range(2, 15)]
    for fam in ("corr", "corr_spec_variant"):
        cfgs += [(fam, i, h, 0) for h in range(1, 13) for i in range(0, 13) if 2 <= i + h <= 14]
    for fam in ("gshare", "gshare_late_variant", "gshare_low_variant"):
        cfgs += [(fam, i, h, 0) for h in range(1, 15) for i in range(0, 14) if 2 <= i + h <= 14]
    cfgs += [("local", i, 0, l) for i in range(0, 11) for l in range(2, 15)]
    cfgs += [("tournament", i, h, l) for i in range(1, 10) for h in range(1, 9) for l in range(2, 14)]
    return [c for c in cfgs if build(*c).bits <= MAX_BITS]


# the configs dev/defines.vh builds today (BP_IDX_BITS 5, BP_HIST_BITS 4, BP_LHIST_BITS 8)
DEFAULTS = {"bimodal": (5, 0, 0), "corr": (5, 4, 0), "gshare": (5, 4, 0), "local": (5, 0, 8),
            "tournament": (5, 4, 8)}
