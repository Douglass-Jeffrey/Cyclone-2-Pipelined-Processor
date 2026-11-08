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
COLOR = {f: "C%d" % k for k, f in enumerate(FAM)}
STYLES = {"plain": "default", "plain_dark": "dark_background"}
WORKLOADS = ("softmul", "hwmul")
SUFFIX = {"softmul": "as_built", "hwmul": "hw_muldiv"}  # file-name suffix, as in the pareto names
OUT = None  # set per style in main()


def wl_title(text, wl):
    """Only the workload without libgcc multiply/divide is named in a title; as built is the default."""
    return text if wl == "softmul" else text + ", without libgcc multiply/divide"


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
    if fig.get_layout_engine() is None:   # grids of panels use constrained layout instead
        fig.tight_layout()
    fig.savefig(os.path.join(OUT, name + ".svg"))
    fig.savefig(os.path.join(OUT, name + ".png"), dpi=150)
    plt.close(fig)


def bits_axis(ax, lo=4, hi=16, step=2):
    ax.set_xscale("log", base=2)
    ticks = [2 ** k for k in range(lo, hi + 1, step)]
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
    ax.set_title(wl_title("Lowest " + ("MPKI" if key == "mpki" else "mean per-program MPKI")
                          + " within each state budget", wl), fontsize=11)
    ax.grid(True)
    ax.legend()
    save(fig, name)


def heat_cells(ax, xs, ys, grid, vmin=None, vmax=None, mark=None, fontsize=7):
    """Draw grid {(x, y): mpki} on ax with each value printed in its cell; mark outlines one (x, y)."""
    z = np.full((len(ys), len(xs)), np.nan)
    for (x, y), v in grid.items():
        z[ys.index(y), xs.index(x)] = v
    im = ax.imshow(z, origin="lower", aspect="auto", vmin=vmin, vmax=vmax)
    mid = ((np.nanmin(z) if vmin is None else vmin) + (np.nanmax(z) if vmax is None else vmax)) / 2
    if mark:
        ax.add_patch(matplotlib.patches.Rectangle((xs.index(mark[0]) - 0.5, ys.index(mark[1]) - 0.5), 1, 1,
                                                  fill=False, ec="red", lw=2.5))
    for yi in range(len(ys)):
        for xi in range(len(xs)):
            if not np.isnan(z[yi, xi]):
                ax.text(xi, yi, "%.0f" % z[yi, xi], ha="center", va="center", fontsize=fontsize,
                        color="white" if z[yi, xi] < mid else "black")
    ax.set_xticks(range(len(xs)), [budget_text(x) for x in xs])
    ax.set_yticks(range(len(ys)), [budget_text(y) for y in ys])
    return im


def fig_heat(sweep, fam, xname, yname, xkey, ykey, title, name, vmax=None):
    """One heatmap file per workload; vmax saturates outliers so the useful range keeps its colours."""
    for wl in WORKLOADS:
        fig, ax = plt.subplots(figsize=(7, 5.5))
        rows = [r for r in sweep if r["family"] == fam and r["workload"] == wl]
        grid = {(xkey(r), ykey(r)): r["mpki"] for r in rows}
        assert len(grid) == len(rows), "more than one config per cell"
        im = heat_cells(ax, sorted({k[0] for k in grid}), sorted({k[1] for k in grid}), grid, vmax=vmax)
        ax.set_xlabel(xname)
        ax.set_ylabel(yname)
        ax.set_title(wl_title(title, wl), fontsize=11)
        fig.colorbar(im, ax=ax, label="MPKI", extend="max" if vmax else "neither")
        save(fig, "%s_%s" % (name, SUFFIX[wl]))


def fig_tournament_grid(sweep, name, final=(5, 4, 10)):
    """Tournament MPKI over local history length and number of histories, one panel per global history
    length on a shared colour scale; final (idx, hist, lhist) is outlined, as in dev/defines.vh."""
    for wl in WORKLOADS:
        rows = [r for r in sweep if r["family"] == "tournament" and r["workload"] == wl]
        xs, ys = sorted({r["lhist_bits"] for r in rows}), sorted({1 << r["idx_bits"] for r in rows})
        gs = sorted({r["hist_bits"] for r in rows})
        lo, hi = min(r["mpki"] for r in rows), max(r["mpki"] for r in rows)
        fig, axes = plt.subplots(2, (len(gs) + 1) // 2, figsize=(16, 8.4), layout="constrained")
        for ax, g in zip(axes.flat, gs):   # every panel keeps its own ticks and labels, to read on its own
            grid = {(r["lhist_bits"], 1 << r["idx_bits"]): r["mpki"] for r in rows if r["hist_bits"] == g}
            im = heat_cells(ax, xs, ys, grid, lo, hi, (final[2], 1 << final[0]) if g == final[1] else None, 6)
            ax.set_title("%d-bit global history" % g, fontsize=12)
            ax.set_xlabel("Local history length (bits)")
            ax.set_ylabel("Number of local histories")
        fig.colorbar(im, ax=axes, label="MPKI", shrink=0.8, pad=0.01)
        fig.suptitle(wl_title("Tournament predictor MPKI at each global history length", wl), fontsize=14)
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
    ax.set_title("MPKI per program, best configuration of each predictor within %s bits" % budget_text(budget))
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
    ax.set_title(wl_title("Combining the PC with the global history", wl), fontsize=11)
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
    ax.set_title(wl_title("Speculative versus late global history update", wl), fontsize=11)
    ax.grid(True)
    ax.legend()
    save(fig, name)


MARKER = {"bimodal": "o", "corr": "s", "gshare": "^", "local": "D", "tournament": "v"}


def fig_cost(q, key, name):
    """One Quartus result (logic_elements or fmax_mhz) per fitted build on a linear bits axis.
    Hollow, distinct markers keep same-size builds apart; the band is the size that ran out of LABs."""
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for k, fam in enumerate(FAM):
        rows = [r for r in q if r["family"] == fam and r["fit"] == "True"]
        ax.plot([r["state_bits"] for r in rows], [r[key] for r in rows], MARKER[fam], ms=8, mfc="none", mew=1.6,
                color="C%d" % k, label=LABEL[fam])
    end = 5120
    ax.axvspan(fpga_limit_bits(q), end, color="gray", alpha=0.25, lw=0)
    ax.text((fpga_limit_bits(q) + end) / 2, 0.5, "Did not fit (out of LABs)", transform=ax.get_xaxis_transform(),
            rotation=90, ha="center", va="center", fontsize=9)
    if key == "logic_elements":
        ax.set_ylim(5000, 15000)
        ax.yaxis.set_major_formatter(matplotlib.ticker.StrMethodFormatter("{x:,.0f}"))
        ax.set_ylabel("Logic elements (whole design)")
        ax.set_title("Logic elements used by the whole design")
        ax.legend(fontsize=9, loc="upper left")
    else:
        ax.axhline(50, color="gray", ls="--", label="Board clock (50 MHz)")
        ax.set_ylim(47, 54.5)
        ax.set_ylabel("Fmax (MHz)")
        ax.set_title("Fmax of the whole design")
        ax.legend(fontsize=9, loc="lower left")
    ax.set_xlim(0, end)
    ax.set_xticks(range(0, end + 1, 1024), ["0"] + ["%dK" % k for k in range(1, end // 1024 + 1)])
    ax.set_xlabel("Predictor state (bits)")
    ax.grid(True)
    save(fig, name)


def fig_breakdown(rows, name):
    fams = FAM[::-1]
    prog = [rows[f]["total"] - rows[f]["lib"] for f in fams]
    lib = [rows[f]["lib"] for f in fams]
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.barh([LABEL[f] for f in fams], prog, label="Program code")
    ax.barh([LABEL[f] for f in fams], lib, left=prog, label="libgcc multiply/divide")
    ax.set_xlabel("Mispredictions over all 19 programs (original default sizes)")
    ax.set_title("Mispredictions in program code and in libgcc multiply/divide")
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
            fig_heat(sweep, "gshare", "Table size (counters)", "Global history length (bits)",
                     lambda r: 1 << (r["idx_bits"] + r["hist_bits"]), lambda r: r["hist_bits"],
                     "Gshare predictor MPKI", "heatmap_gshare", vmax=60)
            fig_heat(sweep, "corr", "Table size (counters)", "Global history length (bits)",
                     lambda r: 1 << (r["idx_bits"] + r["hist_bits"]), lambda r: r["hist_bits"],
                     "Correlating predictor MPKI", "heatmap_corr", vmax=60)
            fig_heat(sweep, "local", "Local history length (bits)", "Number of local histories",
                     lambda r: r["lhist_bits"], lambda r: 1 << r["idx_bits"],
                     "Local predictor MPKI", "heatmap_local")
            fig_tournament_grid(sweep, "heatmap_tournament")
            fig_per_program(sweep, per_prog, 1024, "per_program_1kbit")
            fig_per_program(sweep, per_prog, 8192, "per_program_8kbit")
            for wl in WORKLOADS:
                fig_index(sweep, wl, "variants_index_" + SUFFIX[wl])
                fig_timing(sweep, wl, "variants_timing_" + SUFFIX[wl])
            fig_cost(q, "logic_elements", "cost_les")
            fig_cost(q, "fmax_mhz", "cost_fmax")
            fig_breakdown(bd, "mispredict_breakdown")
    print("figures in", os.path.join(FIGS, "plain*"))


if __name__ == "__main__":
    main()
