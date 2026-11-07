#!/usr/bin/env python3
"""The predictor comparison's figures, and data/pareto.csv.

    python experiments/bp_comparison/plots.py     (after sweep.py, breakdown.py and quartus_cost.py)

Writes data/pareto.csv (the frontier points), then figures/plain/ (matplotlib's default style)
and figures/plain_dark/ (dark_background), one chart per file: the heatmaps and variants come
as <name>_as_built and <name>_hw_muldiv.
"""
import csv
import math
import os
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
FIGS = os.path.join(HERE, "figures")

FAM = ["bimodal", "corr", "gshare", "local", "tournament"]
LABEL = {"bimodal": "Bimodal", "corr": "Correlating", "gshare": "Gshare", "local": "Local",
         "tournament": "Tournament"}
WL = {"softmul": "RV32I as built (software multiply/divide)",
      "hwmul": "Without libgcc multiply/divide (as with an M extension)"}
COLOR = {f: "C%d" % k for k, f in enumerate(FAM)}
STYLES = {"plain": "default", "plain_dark": "dark_background"}
WORKLOADS = ("softmul", "hwmul")
SUFFIX = {"softmul": "as_built", "hwmul": "hw_muldiv"}  # file-name suffix, as in the pareto names
OUT = None  # set per style in main()


# ---- data ---------------------------------------------------------------------
def num(v):
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return v


def load(name):
    with open(os.path.join(DATA, name)) as f:
        return [{k: num(v) for k, v in r.items()} for r in csv.DictReader(f)]


def cfg(r):
    return (r["idx_bits"], r["hist_bits"], r["lhist_bits"])


def frontier(rows, key="mpki", tol=0.001):
    """Points no smaller config beats by more than tol (relative), sorted by bits."""
    best, out = math.inf, []
    for r in sorted(rows, key=lambda r: (r["state_bits"], r[key])):
        if r[key] < best * (1 - tol):
            best = r[key]
            out.append(r)
    return out


def write_pareto(sweep):
    """data/pareto.csv: each buildable family's frontier, per workload."""
    with open(os.path.join(DATA, "pareto.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["workload", "family", "state_bits", "idx_bits", "hist_bits", "lhist_bits", "mpki",
                    "mean_program_mpki", "mispredict_rate"])
        for wl in WORKLOADS:
            for fam in FAM:
                rows = [r for r in sweep if r["family"] == fam and r["workload"] == wl and r["rtl_buildable"] == "True"]
                for r in frontier(rows):
                    w.writerow([wl, fam, r["state_bits"], r["idx_bits"], r["hist_bits"], r["lhist_bits"],
                                r["mpki"], r["mean_program_mpki"], r["mispredict_rate"]])


def best_at_budget(sweep, fam, wl, budget):
    rows = [r for r in sweep if r["family"] == fam and r["workload"] == wl and r["rtl_buildable"] == "True"
            and r["state_bits"] <= budget]
    return min(rows, key=lambda r: r["mpki"])


def fpga_limit_bits(q):
    """The smallest predictor Quartus could not fit on the EP2C20 (state bits)."""
    fails = [r["state_bits"] for r in q if r["fit"] != "True"]
    return min(fails) if fails else 2 ** 12.4


def budget_text(b):
    return "%dK" % (b // 1024) if b >= 1024 else str(b)


def cfg_text(r):
    f, i, h, l = r["family"], r["idx_bits"], r["hist_bits"], r["lhist_bits"]
    return {"bimodal": "%d entries" % (1 << i), "corr": "%d slots x %d-bit hist" % (1 << i, h),
            "gshare": "%d entries, %d-bit hist" % (1 << (i + h), h),
            "local": "%d x %d-bit hist" % (1 << i, l),
            "tournament": "IDX %d, G%d, L%d" % (i, h, l)}[f]


# ---- figures ------------------------------------------------------------------
def save(fig, name):
    os.makedirs(OUT, exist_ok=True)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, name + ".svg"))
    fig.savefig(os.path.join(OUT, name + ".png"), dpi=150)
    plt.close(fig)


def bits_axis(ax):
    ax.set_xscale("log", base=2)
    ticks = [2 ** k for k in range(4, 17, 2)]
    ax.set_xticks(ticks, [("%dK" % (v // 1024)) if v >= 1024 else str(v) for v in ticks])
    ax.minorticks_off()
    ax.set_xlabel("Predictor state (bits)")


def fig_pareto(sweep, wl, key, name, limit_bits):
    """Best MPKI among configs that fit each power-of-two state budget."""
    fig, ax = plt.subplots(figsize=(8, 5))
    for fam in FAM:
        rows = [r for r in sweep if r["family"] == fam and r["workload"] == wl and r["rtl_buildable"] == "True"]
        lo = math.ceil(math.log2(min(r["state_bits"] for r in rows)))
        hi = math.ceil(math.log2(max(r["state_bits"] for r in rows)))
        budgets = [2 ** k for k in range(lo, hi + 1)]
        best = [min(r[key] for r in rows if r["state_bits"] <= b) for b in budgets]
        ax.plot(budgets, best, "o-", ms=4, color=COLOR[fam], label=LABEL[fam])
    static = [r for r in sweep if r["family"] == "static_btfn" and r["workload"] == wl][0][key]
    ax.axhline(static, color="gray", ls="--", label="Static (backward taken)")
    ax.axvline(limit_bits, color=plt.rcParams["text.color"], ls=":", label="EP2C20 fit limit")
    bits_axis(ax)
    ax.set_xlabel("Predictor state budget (bits)")
    ax.set_ylim(bottom=0)
    ax.set_ylabel("Best MPKI" + (" (mean over programs)" if key != "mpki" else ""))
    ax.set_title("Best MPKI vs. predictor size: " + WL[wl], fontsize=11)
    ax.grid(True)
    ax.legend()
    save(fig, name)


def fig_heat(sweep, fam, xname, yname, xkey, ykey, title, name):
    """One heatmap file per workload."""
    for wl in WORKLOADS:
        fig, ax = plt.subplots(figsize=(7, 5.5))
        grid = {(xkey(r), ykey(r)): r["mpki"] for r in sweep if r["family"] == fam and r["workload"] == wl}
        xs, ys = sorted({k[0] for k in grid}), sorted({k[1] for k in grid})
        z = np.full((len(ys), len(xs)), np.nan)
        for (x, y), v in grid.items():
            z[ys.index(y), xs.index(x)] = v
        im = ax.imshow(z, origin="lower", aspect="auto")
        mid = (np.nanmin(z) + np.nanmax(z)) / 2
        for yi in range(len(ys)):
            for xi in range(len(xs)):
                if not np.isnan(z[yi, xi]):
                    ax.text(xi, yi, "%.0f" % z[yi, xi], ha="center", va="center", fontsize=7,
                            color="white" if z[yi, xi] < mid else "black")
        ax.set_xticks(range(len(xs)), [str(x) for x in xs])
        ax.set_yticks(range(len(ys)), [str(y) for y in ys])
        ax.set_xlabel(xname)
        ax.set_ylabel(yname)
        ax.set_title("%s\n%s" % (title, WL[wl]), fontsize=11)
        fig.colorbar(im, ax=ax, label="MPKI")
        save(fig, "%s_%s" % (name, SUFFIX[wl]))


def fig_per_program(sweep, per_prog, budget, name):
    wl = "softmul"
    picks = {f: best_at_budget(sweep, f, wl, budget) for f in FAM}
    pp = defaultdict(dict)
    for r in per_prog:
        for f, p in picks.items():
            if r["workload"] == wl and r["family"] == f and cfg(r) == cfg(p):
                pp[r["program"]][f] = r["mpki"]
    progs = sorted(pp, key=lambda p: -pp[p]["bimodal"])
    x = np.arange(len(progs))
    w = 0.8 / len(FAM)
    fig, ax = plt.subplots(figsize=(13, 5))
    for k, f in enumerate(FAM):
        ax.bar(x + (k - (len(FAM) - 1) / 2) * w, [pp[p][f] for p in progs], w,
               label="%s (%s)" % (LABEL[f], cfg_text(picks[f])))
    ax.set_xticks(x, progs, rotation=45, ha="right")
    ax.set_ylabel("MPKI")
    ax.set_title("MPKI per program, best config within %s bits (as built)" % budget_text(budget))
    ax.grid(True, axis="y")
    ax.legend()
    save(fig, name)


def best_by_size(sweep, fam, wl):
    """Lowest-MPKI config of a global-history family at each table size (idx + hist bits)."""
    out = {}
    for r in sweep:
        if r["family"] == fam and r["workload"] == wl and r["idx_bits"] + r["hist_bits"] >= 4:
            n = r["idx_bits"] + r["hist_bits"]
            if n not in out or r["mpki"] < out[n]["mpki"]:
                out[n] = r
    return out


def fig_index(sweep, wl, name):
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for fam, c, text in (("gshare", "C2", "Gshare, top-bit XOR"), ("gshare_low_variant", "C5", "Gshare, low-bit XOR"),
                         ("corr", "C1", "Correlating (concatenate)")):
        b = best_by_size(sweep, fam, wl)
        ns = sorted(b)
        ax.plot([2 * (1 << n) for n in ns], [b[n]["mpki"] for n in ns], "o-", color=c, label=text)
    bits_axis(ax)
    ax.set_ylabel("MPKI")
    ax.set_title("Index function\n" + WL[wl], fontsize=11)
    ax.grid(True)
    ax.legend()
    save(fig, name)


def fig_timing(sweep, wl, name):
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for spec, late, c, text in (("gshare", "gshare_late_variant", "C2", "Gshare"),
                                ("corr_spec_variant", "corr", "C1", "Correlating")):
        bs, bl = best_by_size(sweep, spec, wl), best_by_size(sweep, late, wl)
        ns = sorted(set(bs) & set(bl))
        ax.plot([2 * (1 << n) for n in ns], [bl[n]["mpki"] - bs[n]["mpki"] for n in ns], "o-", color=c, label=text)
    ax.axhline(0, color="gray")
    bits_axis(ax)
    ax.set_ylabel("MPKI saved by speculative history")
    ax.set_title("History timing\n" + WL[wl], fontsize=11)
    ax.grid(True)
    ax.legend()
    save(fig, name)


def fig_cost(q, name):
    fig, axes = plt.subplots(2, 1, figsize=(8, 8), sharex=True)
    for k, fam in enumerate(FAM):
        rows = sorted([r for r in q if r["family"] == fam and r["fit"] == "True"], key=lambda r: r["state_bits"])
        xs = [r["state_bits"] for r in rows]
        axes[0].plot(xs, [r["logic_elements"] for r in rows], "o-", color="C%d" % k, label=LABEL[fam])
        axes[1].plot(xs, [r["fmax_mhz"] for r in rows], "o", color="C%d" % k, label=LABEL[fam])
    fails = [r for r in q if r["fit"] != "True"]
    axes[0].plot([r["state_bits"] for r in fails], [18752] * len(fails), "x", ms=9, color=plt.rcParams["text.color"],
                 label="Did not fit")
    axes[0].axhline(18752, color="gray", ls="--", label="EP2C20 capacity")
    axes[1].axhline(50, color="gray", ls="--", label="Board clock (50 MHz)")
    axes[0].set_ylim(bottom=0)
    axes[0].set_ylabel("Logic elements (whole SoC)")
    axes[1].set_ylabel("Fmax (MHz)")
    axes[0].set_title("FPGA cost of predictor state (Cyclone II)")
    bits_axis(axes[1])
    for a in axes:
        a.grid(True)
        a.legend()
    save(fig, name)


def fig_breakdown(rows, name):
    fams = FAM[::-1]
    prog = [rows[f]["total"] - rows[f]["lib"] for f in fams]
    lib = [rows[f]["lib"] for f in fams]
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.barh([LABEL[f] for f in fams], prog, label="Program code")
    ax.barh([LABEL[f] for f in fams], lib, left=prog, label="libgcc multiply/divide")
    ax.set_xlabel("Mispredicts, all 19 programs (default sizes)")
    ax.set_title("Where the mispredicts are")
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.18), ncol=2)
    save(fig, name)


def main():
    global OUT
    sweep = load("sweep.csv")
    per_prog = load("sweep_per_program.csv")
    q = load("quartus_defaults.csv") + load("quartus.csv")
    bd = {r["family"]: r for r in load("breakdown.csv")}
    write_pareto(sweep)
    limit = fpga_limit_bits(q)
    for folder, style in STYLES.items():
        OUT = os.path.join(FIGS, folder)
        with plt.style.context(style):
            fig_pareto(sweep, "softmul", "mpki", "pareto_as_built", limit)
            fig_pareto(sweep, "hwmul", "mpki", "pareto_hw_muldiv", limit)
            fig_pareto(sweep, "softmul", "mean_program_mpki", "pareto_as_built_program_mean", limit)
            fig_pareto(sweep, "hwmul", "mean_program_mpki", "pareto_hw_muldiv_program_mean", limit)
            fig_heat(sweep, "gshare", "Index bits (2^n counters)", "Global history bits",
                     lambda r: r["idx_bits"] + r["hist_bits"], lambda r: r["hist_bits"],
                     "Gshare: table size vs. history length (MPKI)", "heatmap_gshare")
            fig_heat(sweep, "corr", "Index bits (2^n counters)", "Global history bits",
                     lambda r: r["idx_bits"] + r["hist_bits"], lambda r: r["hist_bits"],
                     "Correlating: table size vs. history length (MPKI)", "heatmap_corr")
            fig_heat(sweep, "local", "Local history length (bits)", "Slot-history count (log2)",
                     lambda r: r["lhist_bits"], lambda r: r["idx_bits"],
                     "Local: history length vs. number of histories (MPKI)", "heatmap_local")
            fig_per_program(sweep, per_prog, 1024, "per_program_1kbit")
            fig_per_program(sweep, per_prog, 8192, "per_program_8kbit")
            for wl in WORKLOADS:
                fig_index(sweep, wl, "variants_index_" + SUFFIX[wl])
                fig_timing(sweep, wl, "variants_timing_" + SUFFIX[wl])
            fig_cost(q, "cost_les_fmax")
            fig_breakdown(bd, "mispredict_breakdown")
    print("figures in", os.path.join(FIGS, "plain*"))


if __name__ == "__main__":
    main()
