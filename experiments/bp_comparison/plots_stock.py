#!/usr/bin/env python3
"""The predictor comparison's figures in stock matplotlib, for comparison with plots.py.

    python experiments/bp_comparison/plots_stock.py     (after plots.py has written data/pareto.csv)

Same data and chart types as plots.py, drawn with plain matplotlib: the default style
(figures/stock/) and plt.style.use("dark_background") (figures/stock_dark/), default
colors, constrained layout, legends outside the axes.
"""
import importlib.util
import math
import os
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.patches import Patch, Rectangle  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("bp_plots", os.path.join(HERE, "plots.py"))
P = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(P)                     # data helpers only: load, frontier, cfg, ...

FAM = P.FAMILIES
COLOR = {f: "C%d" % k for k, f in enumerate(FAM)}
STYLES = {"stock": "default", "stock_dark": "dark_background"}


def save(fig, name, folder):
    d = os.path.join(P.FIGS, folder)
    os.makedirs(d, exist_ok=True)
    fig.savefig(os.path.join(d, name + ".svg"))
    fig.savefig(os.path.join(d, name + ".png"), dpi=200)
    plt.close(fig)


def bits_axis(ax, lo, hi):
    ax.set_xscale("log", base=2)
    ticks = [2 ** k for k in range(lo, hi + 1, 2)]
    ax.set_xticks(ticks, [("%dK" % (v // 1024)) if v >= 1024 else str(v) for v in ticks])
    ax.minorticks_off()
    ax.set_xlabel("Predictor state (bits, log scale)")


def fig_pareto(sweep, wl, key, name, folder, limit_bits):
    fig, ax = plt.subplots(figsize=(9, 5), layout="constrained")
    for fam in FAM:
        rows = [r for r in sweep if r["family"] == fam and r["workload"] == wl and r["rtl_buildable"] == "True"]
        fr = P.frontier(rows, key)
        ax.step([r["state_bits"] for r in fr], [r[key] for r in fr], where="post", color=COLOR[fam],
                label=P.LABEL[fam])
        d = [r for r in rows if P.cfg(r) == P.DEFAULTS[fam]][0]
        ax.plot(d["state_bits"], d[key], "o", color=COLOR[fam])
    top = {("softmul", "mpki"): 75, ("hwmul", "mpki"): 48, ("softmul", "mean_program_mpki"): 48,
           ("hwmul", "mean_program_mpki"): 32}[(wl, key)]
    r = [r for r in sweep if r["family"] == "static_btfn" and r["workload"] == wl][0]
    if r[key] < top:
        ax.axhline(r[key], color="gray", ls="--", label="Static: backward taken, forward not")
    ax.axvspan(limit_bits, 2 ** 15.4, color="gray", alpha=0.2, label="Did not fit the EP2C20")
    ax.plot([], [], "o", color="gray", label="Built default (dev/defines.vh)")
    bits_axis(ax, 4, 16)
    ax.set_xlim(12, 2 ** 15.4)
    ax.set_ylim(0, top)
    ax.set_ylabel("Mispredicts per 1,000 instructions" + (" (mean over programs)" if key != "mpki" else ""))
    ax.set_title("Best accuracy at each predictor size" + ("" if key == "mpki" else ", per-program mean")
                 + "\n" + P.WL[wl])
    ax.grid(True, alpha=0.3)
    fig.legend(loc="outside right upper")
    save(fig, name, folder)


def heat(ax, grid, xs, ys, fig):
    z = np.full((len(ys), len(xs)), np.nan)
    for (x, y), v in grid.items():
        z[ys.index(y), xs.index(x)] = v
    vmin = np.nanmin(z)
    im = ax.imshow(z, origin="lower", aspect="auto", vmin=vmin, vmax=vmin + 2.0 * (np.nanpercentile(z, 50) - vmin))
    ax.set_xticks(range(len(xs)), [str(x) for x in xs])
    ax.set_yticks(range(len(ys)), [str(y) for y in ys])
    for xi in range(len(xs)):                   # outline the best y for each column, with its value
        col = z[:, xi]
        if np.all(np.isnan(col)):
            continue
        yi = int(np.nanargmin(col))
        ax.add_patch(Rectangle((xi - 0.5, yi - 0.5), 1, 1, fill=False, ec="red", lw=1.5))
        ax.text(xi, yi, "%.0f" % col[yi], ha="center", va="center", fontsize=7, color="white")
    fig.colorbar(im, ax=ax, label="Mispredicts / 1,000 instructions", extend="max")


def fig_heat(sweep, fam, xname, yname, xkey, ykey, title, name, folder):
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.8), layout="constrained")
    for ax, wl in zip(axes, ("softmul", "hwmul")):
        grid = {(xkey(r), ykey(r)): r["mpki"] for r in sweep if r["family"] == fam and r["workload"] == wl}
        heat(ax, grid, sorted({k[0] for k in grid}), sorted({k[1] for k in grid}), fig)
        ax.set_xlabel(xname)
        ax.set_ylabel(yname)
        ax.set_title("As built" if wl == "softmul" else "Without libgcc multiply/divide")
    fig.suptitle(title + " (red box: best setting per column)")
    save(fig, name, folder)


def fig_per_program(sweep, per_prog, budget, name, folder):
    wl = "softmul"
    picks = {f: P.best_at_budget(sweep, f, wl, budget) for f in FAM}
    pp = defaultdict(dict)
    for r in per_prog:
        for f, p in picks.items():
            if r["workload"] == wl and r["family"] == f and P.cfg(r) == P.cfg(p):
                pp[r["program"]][f] = r["mpki"]
    progs = sorted(pp, key=lambda p: -pp[p]["bimodal"])
    others = FAM[1:]
    z = np.array([[pp[p][f] - pp[p]["bimodal"] for f in others] for p in progs])
    fig, ax = plt.subplots(figsize=(7.6, 8.6), layout="constrained")
    im = ax.imshow(np.clip(z, -15, 15), aspect="auto", cmap="RdBu_r", vmin=-15, vmax=15)
    for yi in range(len(progs)):
        for xi in range(len(others)):
            ax.text(xi, yi, "%+.1f" % z[yi, xi], ha="center", va="center", fontsize=7.5, color="black")
    ax.set_xticks(range(len(others)), ["%s\n%s" % (P.LABEL[f], P.cfg_text(picks[f])) for f in others], fontsize=8)
    ax.set_yticks(range(len(progs)), ["%s (%.1f)" % (p, pp[p]["bimodal"]) for p in progs], fontsize=8.5)
    ax.set_title("Change in MPKI vs. bimodal, best config within %s bits, as built\n"
                 "(brackets: bimodal's MPKI)" % P.budget_text(budget))
    fig.colorbar(im, ax=ax, label="MPKI minus bimodal's (blue: better)", shrink=0.6)
    save(fig, name, folder)


def fig_variants(sweep, name, folder):
    fig, axes = plt.subplots(2, 2, figsize=(12.5, 9), layout="constrained")

    def best_by_size(fam, wl):
        out = {}
        for r in sweep:
            if r["family"] == fam and r["workload"] == wl and r["idx_bits"] + r["hist_bits"] >= 4:
                n = r["idx_bits"] + r["hist_bits"]
                if n not in out or r["mpki"] < out[n]["mpki"]:
                    out[n] = r
        return out

    for row, wl in enumerate(("softmul", "hwmul")):
        tag = "as built" if wl == "softmul" else "without libgcc multiply/divide"
        ax = axes[row][0]
        for fam, c, text in (("gshare", "C2", "Gshare, top-bit XOR"),
                             ("gshare_low_variant", "C5", "Gshare, low-bit XOR"),
                             ("corr", "C1", "Correlating (concatenate)")):
            b = best_by_size(fam, wl)
            ns = sorted(b)
            ax.plot([2 * (1 << n) for n in ns], [b[n]["mpki"] for n in ns], "o-", color=c, label=text)
        bits_axis(ax, 4, 16)
        ax.set_ylabel("Mispredicts / 1,000 instructions")
        ax.set_title("Index function, " + tag)
        ax.grid(True, alpha=0.3)
        ax = axes[row][1]
        for (spec, late), c, text in ((("gshare", "gshare_late_variant"), "C2", "Gshare"),
                                      (("corr_spec_variant", "corr"), "C1", "Correlating")):
            bs, bl = best_by_size(spec, wl), best_by_size(late, wl)
            ns = sorted(set(bs) & set(bl))
            ax.plot([2 * (1 << n) for n in ns], [bl[n]["mpki"] - bs[n]["mpki"] for n in ns], "o-", color=c, label=text)
        ax.axhline(0, color="gray", lw=1)
        bits_axis(ax, 4, 16)
        ax.set_ylim(-1.5, 1.5)
        ax.set_ylabel("MPKI saved by speculative history")
        ax.set_title("History timing, " + tag)
        ax.grid(True, alpha=0.3)
        if row == 0:
            for a in axes[0]:
                a.legend(loc="upper left", bbox_to_anchor=(1.02, 1))
    fig.suptitle("What gshare's two differences from correlating are worth")
    save(fig, name, folder)


def fig_cost(q, name, folder):
    fig, axes = plt.subplots(2, 1, figsize=(9, 8), sharex=True, layout="constrained")
    for fam in FAM:
        rows = sorted([r for r in q if r["family"] == fam and r["fit"] == "True"], key=lambda r: r["state_bits"])
        xs = [r["state_bits"] for r in rows]
        axes[0].plot(xs, [r["logic_elements"] for r in rows], "o-", color=COLOR[fam], label=P.LABEL[fam])
        axes[1].plot(xs, [r["fmax_mhz"] for r in rows], "o", color=COLOR[fam])
        for r in [r for r in q if r["family"] == fam and r["fit"] != "True"]:
            axes[0].plot(r["state_bits"], 18752, "x", ms=9, mew=2, color=COLOR[fam])
    axes[0].axhline(18752, color="gray", ls="--", label="EP2C20 capacity (18,752 LEs)")
    axes[0].plot([], [], "x", color="gray", label="Did not fit")
    axes[1].axhline(50, color="gray", ls=":", label="Board clock (50 MHz)")
    axes[0].set_ylabel("Logic elements (whole SoC)")
    axes[1].set_ylabel("Fmax, slow corner (MHz)")
    axes[0].set_ylim(0, 21000)
    axes[1].set_ylim(46.8, 54.5)
    bits_axis(axes[1], 4, 14)
    axes[1].set_xlim(32, 2 ** 13.3)
    for a in axes:
        a.grid(True, alpha=0.3)
    fig.suptitle("What predictor state costs on the Cyclone II (Quartus 13.0sp1, whole SoC)")
    fig.legend(loc="outside right upper")
    save(fig, name, folder)


def fig_breakdown(rows, name, folder):
    fams = FAM[::-1]
    fig, ax = plt.subplots(figsize=(9, 3.6), layout="constrained")
    prog = [rows[f]["total"] - rows[f]["lib"] for f in fams]
    lib = [rows[f]["lib"] for f in fams]
    ax.barh([P.LABEL[f] for f in fams], prog, label="Program code")
    bars = ax.barh([P.LABEL[f] for f in fams], lib, left=prog, label="libgcc multiply/divide")
    ax.bar_label(bars, labels=["%.0f%% in libgcc" % (100.0 * rows[f]["lib"] / rows[f]["total"]) for f in fams],
                 padding=3, fontsize=8.5)
    ax.set_xlim(0, max(r["total"] for r in rows.values()) * 1.22)
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: "%dK" % (v / 1000) if v else "0"))
    ax.set_xlabel("Mispredicts, all 19 programs (default sizes)")
    ax.set_title("Where the mispredicts are")
    fig.legend(loc="outside right upper")
    save(fig, name, folder)


def main():
    sweep = P.load("sweep.csv")
    per_prog = P.load("sweep_per_program.csv")
    q = P.load("quartus_defaults.csv") + P.load("quartus.csv")
    bd = {r["family"]: r for r in P.load("breakdown.csv")}
    limit = P.fpga_limit_bits(q)
    for folder, style in STYLES.items():
        with plt.style.context(style):
            fig_pareto(sweep, "softmul", "mpki", "pareto_as_built", folder, limit)
            fig_pareto(sweep, "hwmul", "mpki", "pareto_hw_muldiv", folder, limit)
            fig_pareto(sweep, "softmul", "mean_program_mpki", "pareto_as_built_program_mean", folder, limit)
            fig_pareto(sweep, "hwmul", "mean_program_mpki", "pareto_hw_muldiv_program_mean", folder, limit)
            fig_heat(sweep, "gshare", "Table size: index bits (2^n counters)", "Global history bits",
                     lambda r: r["idx_bits"] + r["hist_bits"], lambda r: r["hist_bits"],
                     "Gshare: table size vs. history length", "heatmap_gshare", folder)
            fig_heat(sweep, "corr", "Table size: index bits (2^n counters)", "Global history bits",
                     lambda r: r["idx_bits"] + r["hist_bits"], lambda r: r["hist_bits"],
                     "Correlating: table size vs. history length", "heatmap_corr", folder)
            fig_heat(sweep, "local", "Local history length (bits)", "Slot-history count (log2)",
                     lambda r: r["lhist_bits"], lambda r: r["idx_bits"],
                     "Local: history length vs. number of histories", "heatmap_local", folder)
            fig_per_program(sweep, per_prog, 1024, "per_program_1kbit", folder)
            fig_per_program(sweep, per_prog, 8192, "per_program_8kbit", folder)
            fig_variants(sweep, "variants", folder)
            fig_cost(q, "cost_les_fmax", folder)
            fig_breakdown(bd, "mispredict_breakdown", folder)
    print("figures in", os.path.join(P.FIGS, "stock"), "and stock_dark")


if __name__ == "__main__":
    main()
