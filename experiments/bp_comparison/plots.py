#!/usr/bin/env python3
"""Figures for the predictor comparison, each in a light and a dark version.

    python experiments/bp_comparison/plots.py     (after sweep.py, quartus_cost.py)

Writes figures/{light,dark}/<name>.{svg,png} and data/pareto.csv.
"""
import csv
import math
import os
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
FIGS = os.path.join(HERE, "figures")

FAMILIES = ["bimodal", "corr", "gshare", "local", "tournament"]
LABEL = {"bimodal": "Bimodal", "corr": "Correlating", "gshare": "Gshare", "local": "Local",
         "tournament": "Tournament", "gshare_low_variant": "Gshare, low-bit XOR",
         "corr_spec_variant": "Correlating, speculative history",
         "gshare_late_variant": "Gshare, history at training"}
WL = {"softmul": "RV32I as built (software multiply/divide)",
      "hwmul": "Without libgcc multiply/divide (as with an M extension)"}

# validated categorical slots (dataviz reference palette; light/dark steps)
THEMES = {
    "light": dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e", muted="#898781", grid="#e1e0d9",
                  axis="#c3c2b7", neutral="#f0efec",
                  series={"bimodal": "#2a78d6", "corr": "#eb6834", "gshare": "#1baf7a", "local": "#eda100",
                          "tournament": "#e87ba4", "green": "#008300", "violet": "#6250d6", "red": "#e34948"},
                  seq=["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"],
                  div=["#184f95", "#5598e7", "#f0efec", "#ec8f8e", "#b8302f"]),
    "dark": dict(surface="#1a1a19", ink="#f0efec", ink2="#c3c2b7", muted="#898781", grid="#2c2c2a",
                 axis="#383835", neutral="#383835",
                 series={"bimodal": "#3987e5", "corr": "#d95926", "gshare": "#199e70", "local": "#c98500",
                         "tournament": "#d55181", "green": "#008300", "violet": "#9085e9", "red": "#e66767"},
                 seq=["#0d366b", "#184f95", "#256abf", "#3987e5", "#6da7ec", "#9ec5f4", "#cde2fb"],
                 div=["#5598e7", "#256abf", "#383835", "#b8302f", "#ec8f8e"]),
}
DEFAULTS = {"bimodal": (5, 0, 0), "corr": (5, 4, 0), "gshare": (5, 4, 0), "local": (5, 0, 8),
            "tournament": (5, 4, 8)}


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


# ---- style --------------------------------------------------------------------
def setup(theme):
    t = THEMES[theme]
    plt.rcParams.update({
        "font.family": ["Segoe UI", "DejaVu Sans", "sans-serif"], "font.size": 10,
        "figure.facecolor": t["surface"], "axes.facecolor": t["surface"], "savefig.facecolor": t["surface"],
        "axes.edgecolor": t["axis"], "axes.labelcolor": t["ink2"], "axes.titlecolor": t["ink"],
        "axes.titlesize": 12, "axes.titleweight": "semibold", "axes.titlelocation": "left",
        "axes.titlepad": 10, "xtick.color": t["muted"], "ytick.color": t["muted"],
        "xtick.labelcolor": t["ink2"], "ytick.labelcolor": t["ink2"], "axes.linewidth": 1,
        "grid.color": t["grid"], "grid.linewidth": 1, "grid.linestyle": "-", "axes.grid": True,
        "axes.axisbelow": True, "axes.spines.top": False, "axes.spines.right": False,
        "legend.frameon": True, "legend.facecolor": t["surface"], "legend.edgecolor": t["axis"],
        "legend.framealpha": 1, "legend.labelcolor": t["ink2"], "text.color": t["ink"],
        "svg.fonttype": "none", "lines.solid_capstyle": "round", "lines.solid_joinstyle": "round",
    })
    return t


def save(fig, name, theme):
    d = os.path.join(FIGS, theme)
    os.makedirs(d, exist_ok=True)
    fig.savefig(os.path.join(d, name + ".svg"), bbox_inches="tight", pad_inches=0.25)
    fig.savefig(os.path.join(d, name + ".png"), dpi=200, bbox_inches="tight", pad_inches=0.25)
    plt.close(fig)


def titles(ax, title, sub, t, size=12):
    ax.set_title(title, pad=24, fontsize=size)
    ax.text(0, 1.02, sub, transform=ax.transAxes, fontsize=9, color=t["ink2"], va="bottom")


def fpga_limit_bits(q):
    """The smallest predictor Quartus could not fit on the EP2C20 (state bits)."""
    fails = [r["state_bits"] for r in q if r["fit"] != "True"]
    return min(fails) if fails else 2 ** 12.4


def bits_axis(ax, lo=4, hi=16):
    ax.set_xscale("log", base=2)
    ticks = [2 ** k for k in range(lo, hi + 1, 2)]
    ax.set_xticks(ticks)
    ax.set_xticklabels([("%dK" % (v // 1024)) if v >= 1024 else str(v) for v in ticks])
    ax.minorticks_off()
    ax.set_xlabel("Predictor state (bits = flip-flops on this FPGA, log scale)")


def point(ax, x, y, color, t, size=8, zorder=5):
    ax.plot([x], [y], "o", ms=size, color=color, mec=t["surface"], mew=2, zorder=zorder)


# ---- figures ------------------------------------------------------------------
def fig_pareto(sweep, wl, key, theme, name, limit_bits):
    t = setup(theme)
    fig, ax = plt.subplots(figsize=(8.6, 5.2))
    for fam in FAMILIES:
        rows = [r for r in sweep if r["family"] == fam and r["workload"] == wl and r["rtl_buildable"] == "True"]
        fr = frontier(rows, key)
        xs, ys = [r["state_bits"] for r in fr], [r[key] for r in fr]
        c = t["series"][fam]
        ax.step(xs, ys, where="post", color=c, lw=2, label=LABEL[fam], zorder=3)
        d = [r for r in rows if cfg(r) == DEFAULTS[fam]][0]
        point(ax, d["state_bits"], d[key], c, t, size=10)
    top = {("softmul", "mpki"): 75, ("hwmul", "mpki"): 48, ("softmul", "mean_program_mpki"): 48,
           ("hwmul", "mean_program_mpki"): 32}[(wl, key)]
    off = []
    for fam, text in (("static_not_taken", "always not-taken"), ("static_btfn", "backward taken, forward not")):
        r = [r for r in sweep if r["family"] == fam and r["workload"] == wl][0]
        if r[key] < top:
            ax.axhline(r[key], color=t["muted"], lw=1, zorder=1)
            ax.text(2 ** 8.5, r[key], " Static, no state: %s (%.0f)" % (text, r[key]), color=t["ink2"],
                    fontsize=8.5, va="bottom")
        else:
            off.append("%s %.0f" % (text, r[key]))
    bits_axis(ax, 4, 16)
    ax.set_xlim(12, 2 ** 15.4)
    ax.set_ylim(0, top)
    notes = []
    if off:
        notes.append("Off scale: static " + "; ".join(off) + " MPKI, and the smallest tables.")
    dc = [r for r in sweep if r["family"] == "corr" and r["workload"] == wl and cfg(r) == DEFAULTS["corr"]][0]
    dg = [r for r in sweep if r["family"] == "gshare" and r["workload"] == wl and cfg(r) == DEFAULTS["gshare"]][0]
    if abs(dc[key] - dg[key]) < 1:
        notes.append("Correlating's default dot is under gshare's (both 1,028 bits: %.1f and %.1f)."
                     % (dc[key], dg[key]))
    if notes:
        ax.text(0.01, 0.02, "\n".join(notes), transform=ax.transAxes, color=t["ink2"], fontsize=8.5,
                va="bottom")
    ax.set_ylabel("Mispredicts per 1,000 instructions" + (" (mean over programs)" if key != "mpki" else ""))
    titles(ax, "Best accuracy at each predictor size" + ("" if key == "mpki" else ", per-program mean"),
           WL[wl] + "; 19 programs. Lines: the best config at or below each size; "
           "dots: the configs dev/defines.vh builds.", t)
    ax.axvspan(limit_bits, 2 ** 15.4, color=t["grid"], alpha=0.5, lw=0, zorder=0)
    ax.text(limit_bits * 1.08, top * 0.9, "Did not fit\nthe EP2C20", color=t["ink2"], fontsize=8, va="top")
    ax.plot([], [], "o", ms=8, color=t["muted"], mec=t["surface"], mew=2, label="Built default")
    ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1), borderaxespad=0, fontsize=9)
    save(fig, name, theme)


def heat(ax, grid, xs, ys, t, fmt="%.0f", best_per_col=True, cmap_steps=None):
    import numpy as np
    z = np.full((len(ys), len(xs)), np.nan)
    for (x, y), v in grid.items():
        z[ys.index(y), xs.index(x)] = v
    cmap = LinearSegmentedColormap.from_list("seq", cmap_steps or t["seq"])
    cmap.set_bad(t["surface"])
    vmin = np.nanmin(z)
    vmax = vmin + 2.0 * (np.nanpercentile(z, 50) - vmin)     # spend the ramp on the good configs
    im = ax.imshow(z, origin="lower", aspect="auto", cmap=cmap, vmin=vmin, vmax=vmax,
                   extent=(-0.5, len(xs) - 0.5, -0.5, len(ys) - 0.5))
    ax.grid(False)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.set_xticks(range(len(xs)))
    ax.set_yticks(range(len(ys)))
    ax.set_xticklabels([str(x) for x in xs])
    ax.set_yticklabels([str(y) for y in ys])
    ax.tick_params(length=0)
    if best_per_col:
        for xi in range(len(xs)):
            col = z[:, xi]
            if np.all(np.isnan(col)):
                continue
            yi = int(np.nanargmin(col))
            v = col[yi]
            frac = (v - vmin) / (vmax - vmin + 1e-12)
            ink = "#ffffff" if (frac > 0.45) == (t["surface"] == "#fcfcfb") else "#0b0b0b"
            ax.add_patch(plt.Rectangle((xi - 0.5, yi - 0.5), 1, 1, fill=False, ec=t["ink"], lw=1.5))
            ax.text(xi, yi, fmt % v, ha="center", va="center", fontsize=7.5, color=ink)
    return im


def fig_knob_heatmaps(sweep, fam, xname, yname, xkey, ykey, title, theme, name):
    t = setup(theme)
    fig, axes = plt.subplots(1, 2, figsize=(11.5, 4.8))
    for ax, wl in zip(axes, ("softmul", "hwmul")):
        rows = [r for r in sweep if r["family"] == fam and r["workload"] == wl]
        grid = {(xkey(r), ykey(r)): r["mpki"] for r in rows}
        xs = sorted({k[0] for k in grid})
        ys = sorted({k[1] for k in grid})
        im = heat(ax, grid, xs, ys, t)
        ax.set_xlabel(xname)
        ax.set_ylabel(yname)
        ax.set_title(("As built" if wl == "softmul" else "Without libgcc multiply/divide"), fontsize=10.5)
        cb = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.03, extend="max")
        cb.set_label("Mispredicts / 1,000 instructions", color=t["ink2"])
        cb.outline.set_visible(False)
        cb.ax.tick_params(color=t["muted"], labelcolor=t["ink2"])
    fig.suptitle(title, x=0.06, ha="left", fontsize=12.5, fontweight="semibold", color=t["ink"])
    fig.text(0.06, 0.905, "19 programs. Each outlined cell, with its value, is the best setting "
             "of the y-axis knob for that column.", fontsize=9, color=t["ink2"])
    fig.subplots_adjust(top=0.82, wspace=0.28)
    save(fig, name, theme)


def best_at_budget(sweep, fam, wl, budget):
    rows = [r for r in sweep if r["family"] == fam and r["workload"] == wl and r["rtl_buildable"] == "True"
            and r["state_bits"] <= budget]
    return min(rows, key=lambda r: r["mpki"])


def fig_per_program(sweep, per_prog, budget, theme, name):
    import numpy as np
    t = setup(theme)
    wl = "softmul"
    picks = {f: best_at_budget(sweep, f, wl, budget) for f in FAMILIES}
    pp = defaultdict(dict)
    for r in per_prog:
        if r["workload"] != wl:
            continue
        for f, p in picks.items():
            if r["family"] == f and cfg(r) == cfg(p):
                pp[r["program"]][f] = r["mpki"]
    progs = sorted(pp, key=lambda p: -pp[p]["bimodal"])
    others = FAMILIES[1:]
    z = np.array([[pp[p][f] - pp[p]["bimodal"] for f in others] for p in progs])
    lim = 15
    cmap = LinearSegmentedColormap.from_list("div", t["div"])
    fig, ax = plt.subplots(figsize=(7.6, 8.4))
    ax.imshow(np.clip(z, -lim, lim), aspect="auto", cmap=cmap, vmin=-lim, vmax=lim)
    ax.grid(False)
    for s in ax.spines.values():
        s.set_visible(False)
    for yi in range(len(progs)):
        for xi in range(len(others)):
            v = z[yi, xi]
            strong = abs(v) > lim * 0.55
            ink = "#ffffff" if strong else t["ink"]
            ax.text(xi, yi, "%+.1f" % v if abs(v) >= 0.05 else "0", ha="center", va="center", fontsize=8,
                    color=ink)
    ax.set_xticks(range(len(others)))
    ax.set_xticklabels(["%s\n%s" % (LABEL[f], cfg_text(picks[f])) for f in others], fontsize=8.5)
    ax.xaxis.tick_top()
    ax.set_yticks(range(len(progs)))
    ax.set_yticklabels(["%s  (%.1f)" % (p, pp[p]["bimodal"]) for p in progs], fontsize=8.5)
    ax.tick_params(length=0)
    ax.set_title("Change in MPKI vs. bimodal, at %s bits of state" % budget_text(budget), pad=58)
    ax.text(0, 1.085, "Each predictor's best config within %s bits, as built. Blue: fewer mispredicts per 1,000\n"
            "instructions than bimodal (%s); red: more. Brackets: bimodal's MPKI." % (
                budget_text(budget), cfg_text(picks["bimodal"])),
            transform=ax.transAxes, fontsize=8.5, color=t["ink2"])
    save(fig, name, theme)
    return picks


def budget_text(b):
    return "%dK" % (b // 1024) if b >= 1024 else str(b)


def cfg_text(r):
    f, i, h, l = r["family"], r["idx_bits"], r["hist_bits"], r["lhist_bits"]
    return {"bimodal": "%d entries" % (1 << i), "corr": "%d slots x %d-bit hist" % (1 << i, h),
            "gshare": "%d entries, %d-bit hist" % (1 << (i + h), h),
            "local": "%d x %d-bit hist" % (1 << i, l),
            "tournament": "IDX %d, G%d, L%d" % (i, h, l)}[f]


def fig_variants(sweep, theme, name):
    t = setup(theme)
    fig, axes = plt.subplots(2, 2, figsize=(12, 9.4))

    def best_by_size(fam, wl):
        out = {}
        for r in sweep:
            if r["family"] == fam and r["workload"] == wl and r["idx_bits"] + r["hist_bits"] >= 4:
                n = r["idx_bits"] + r["hist_bits"]
                if n not in out or r["mpki"] < out[n]["mpki"]:
                    out[n] = r
        return out

    for row, wl in enumerate(("softmul", "hwmul")):
        tag = "As built" if wl == "softmul" else "Without libgcc multiply/divide"
        ax = axes[row][0]
        lo, hi = math.inf, 0
        for fam, col in (("gshare", "gshare"), ("gshare_low_variant", "violet"), ("corr", "corr")):
            b = best_by_size(fam, wl)
            ns = sorted(b)
            xs, ys = [2 * (1 << n) for n in ns], [b[n]["mpki"] for n in ns]
            lo, hi = min(lo, min(ys)), max(hi, max(ys))
            ax.plot(xs, ys, color=t["series"][col], lw=2, marker="o", ms=5, mec=t["surface"], mew=1.5,
                    label=LABEL[fam])
        bits_axis(ax, 4, 16)
        ax.set_xlim(24, 2 ** 15.6)
        ax.set_ylim(lo * 0.9, hi * 1.04)
        ax.set_ylabel("Mispredicts / 1,000 instructions")
        titles(ax, "Index function: %s" % tag.lower(),
               "Same table size, best history length at each size (axis not from 0)", t, 11)
        if row == 0:
            for h in ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1), borderaxespad=0, fontsize=8.5).get_lines():
                h.set_markeredgewidth(0)            # solid keys: the plot's marker rings would cut them

        ax = axes[row][1]
        for (spec, late), col, text in ((("gshare", "gshare_late_variant"), "gshare", "Gshare (XOR top)"),
                                        (("corr_spec_variant", "corr"), "corr", "Correlating (concatenate)")):
            bs, bl = best_by_size(spec, wl), best_by_size(late, wl)
            ns = sorted(set(bs) & set(bl))
            xs = [2 * (1 << n) for n in ns]
            ys = [bl[n]["mpki"] - bs[n]["mpki"] for n in ns]
            ax.plot(xs, ys, color=t["series"][col], lw=2, marker="o", ms=5, mec=t["surface"], mew=1.5,
                    label=text)
        ax.axhline(0, color=t["axis"], lw=1)
        bits_axis(ax, 4, 16)
        ax.set_xlim(24, 2 ** 15.6)
        ax.set_ylabel("MPKI saved by speculative history")
        ax.set_ylim(-1.5, 1.5)
        titles(ax, "History timing: %s" % tag.lower(),
               "At-training MPKI minus speculative MPKI (above 0: speculative wins)", t, 11)
        if row == 0:
            for h in ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1), borderaxespad=0, fontsize=8.5).get_lines():
                h.set_markeredgewidth(0)            # solid keys: the plot's marker rings would cut them
    fig.suptitle("What gshare's two differences from correlating are worth", x=0.06, ha="left",
                 fontsize=12.5, fontweight="semibold", color=t["ink"])
    fig.subplots_adjust(top=0.89, wspace=0.75, hspace=0.55)
    save(fig, name, theme)


def fig_cost(q, theme, name):
    t = setup(theme)
    fig, axes = plt.subplots(2, 1, figsize=(8.2, 8), sharex=True)
    for key, ax, ylab, ref, reftext in (
            ("logic_elements", axes[0], "Logic elements (whole SoC)", 18752, "EP2C20 total: 18,752 LEs"),
            ("fmax_mhz", axes[1], "Fmax, slow corner (MHz)", 50, "Board clock: 50 MHz")):
        for fam in FAMILIES:
            rows = sorted([r for r in q if r["family"] == fam and r["fit"] == "True"], key=lambda r: r["state_bits"])
            if not rows:
                continue
            xs, ys = [r["state_bits"] for r in rows], [r[key] for r in rows]
            if key == "logic_elements":         # LEs grow with bits; Fmax depends on shape, so no line
                ax.plot(xs, ys, color=t["series"][fam], lw=2, label=LABEL[fam])
            for x, y in zip(xs, ys):
                point(ax, x, y, t["series"][fam], t, size=8)
            if key == "fmax_mhz":
                for r in rows:
                    if r["meets_50mhz"] != "True":
                        dy = 9 if r["family"] == "tournament" else -9
                        ax.annotate("%s %s: misses 50 MHz" % (LABEL[r["family"]], cfg_text(r)),
                                    (r["state_bits"], r[key]), xytext=(-8, dy),
                                    textcoords="offset points", ha="right", va="center",
                                    fontsize=8.5, color=t["ink2"])
            if key == "logic_elements":
                for r in [r for r in q if r["family"] == fam and r["fit"] != "True"]:
                    ax.plot([r["state_bits"]], [ref], "x", ms=9, mew=2, color=t["series"][fam], zorder=6)
        ax.axhline(ref, color=t["muted"], lw=1)
        ax.text(36, ref, reftext, color=t["ink2"], fontsize=8.5, va="bottom" if key == "logic_elements" else "top")
        ax.set_ylabel(ylab)
    bits_axis(axes[1], 4, 14)
    axes[1].set_xlim(32, 2 ** 13.3)
    axes[0].set_ylim(0, 21000)
    axes[0].yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: "{:,.0f}".format(v)))
    from matplotlib.lines import Line2D
    axes[0].legend(handles=[Line2D([], [], color=t["series"][f], lw=2, marker="o", ms=7, mew=0,
                                   label=LABEL[f]) for f in FAMILIES]
                   + [Line2D([], [], ls="", marker="x", ms=8, mew=2, color=t["muted"], label="Did not fit")],
                   loc="upper left", bbox_to_anchor=(1.02, 1), borderaxespad=0, fontsize=9)
    titles(axes[0], "What predictor state costs on the Cyclone II",
           "Whole SoC compiled by Quartus 13.0sp1 for each config. x: did not fit (more LABs than the "
           "EP2C20 has).", t)
    axes[1].text(0.99, 0.97, "One placement per config: about 1 MHz of this is seed noise.",
                 transform=axes[1].transAxes, color=t["ink2"], fontsize=8.5, ha="right", va="top")
    fails = sorted({LABEL[r["family"]] for r in q if r["fit"] != "True"})
    if fails:
        x = min(r["state_bits"] for r in q if r["fit"] != "True")
        axes[0].annotate("Did not fit at ~4 Kbit:\n" + ", ".join(fails), (x, 18752), xytext=(-10, -14),
                         textcoords="offset points", ha="right", va="top", fontsize=8.5, color=t["ink2"])
    axes[1].set_ylim(46.8, 54.5)
    save(fig, name, theme)


def fig_breakdown(rows, theme, name):
    t = setup(theme)
    fig, ax = plt.subplots(figsize=(8.2, 3.6))
    fams = FAMILIES[::-1]
    for k, fam in enumerate(fams):
        r = rows[fam]
        lib, rest = r["lib"], r["total"] - r["lib"]
        ax.barh(k, rest, height=0.34, color=t["series"]["violet"], edgecolor=t["surface"], lw=2)
        ax.barh(k, lib, left=rest, height=0.34, color=t["muted"], edgecolor=t["surface"], lw=2)
        ax.text(r["total"] * 1.01, k, "%.0f%% in libgcc" % (100.0 * lib / r["total"]), va="center",
                fontsize=8.5, color=t["ink2"])
    ax.set_yticks(range(len(fams)))
    ax.set_yticklabels([LABEL[f] for f in fams])
    ax.grid(axis="y", visible=False)
    ax.set_xlim(0, max(r["total"] for r in rows.values()) * 1.22)
    ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: "%dK" % (v / 1000) if v else "0"))
    ax.set_xlabel("Mispredicts, all 19 programs (default sizes)")
    from matplotlib.patches import Patch
    ax.legend(handles=[Patch(color=t["series"]["violet"], label="Program code"),
                       Patch(color=t["muted"], label="libgcc multiply/divide (__mulsi3, __udivsi3, ...)")],
              loc="upper left", bbox_to_anchor=(1.02, 1), borderaxespad=0, fontsize=8.5)
    ax.set_title("Where the mispredicts are", pad=24)
    ax.text(0, 1.03, "RV32I has no multiply or divide instruction, so each a * b or a / b runs a loop of branches.",
            transform=ax.transAxes, fontsize=9, color=t["ink2"], va="bottom")
    save(fig, name, theme)


def main():
    sweep = load("sweep.csv")
    per_prog = load("sweep_per_program.csv")
    q = []
    for f in ("quartus_defaults.csv", "quartus.csv"):
        if os.path.exists(os.path.join(DATA, f)):
            q += load(f)
    # frontier table
    with open(os.path.join(DATA, "pareto.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["workload", "family", "state_bits", "idx_bits", "hist_bits", "lhist_bits", "mpki",
                    "mean_program_mpki", "mispredict_rate"])
        for wl in ("softmul", "hwmul"):
            for fam in FAMILIES:
                rows = [r for r in sweep if r["family"] == fam and r["workload"] == wl and r["rtl_buildable"] == "True"]
                for r in frontier(rows):
                    w.writerow([wl, fam, r["state_bits"], r["idx_bits"], r["hist_bits"], r["lhist_bits"],
                                r["mpki"], r["mean_program_mpki"], r["mispredict_rate"]])
    bd = {}
    if os.path.exists(os.path.join(DATA, "breakdown.csv")):
        bd = {r["family"]: r for r in load("breakdown.csv")}
    limit = fpga_limit_bits(q)
    print("smallest config that did not fit: %.0f bits of predictor state" % limit)
    for theme in ("light", "dark"):
        fig_pareto(sweep, "softmul", "mpki", theme, "pareto_as_built", limit)
        fig_pareto(sweep, "hwmul", "mpki", theme, "pareto_hw_muldiv", limit)
        fig_pareto(sweep, "softmul", "mean_program_mpki", theme, "pareto_as_built_program_mean", limit)
        fig_pareto(sweep, "hwmul", "mean_program_mpki", theme, "pareto_hw_muldiv_program_mean", limit)
        fig_knob_heatmaps(sweep, "gshare", "Table size: index bits (2^n counters)", "Global history bits",
                          lambda r: r["idx_bits"] + r["hist_bits"], lambda r: r["hist_bits"],
                          "Gshare: table size vs. history length", theme, "heatmap_gshare")
        fig_knob_heatmaps(sweep, "corr", "Table size: index bits (2^n counters)", "Global history bits",
                          lambda r: r["idx_bits"] + r["hist_bits"], lambda r: r["hist_bits"],
                          "Correlating: table size vs. history length", theme, "heatmap_corr")
        fig_knob_heatmaps(sweep, "local", "Local history length (bits)", "Slot-history count (log2)",
                          lambda r: r["lhist_bits"], lambda r: r["idx_bits"],
                          "Local: per-branch history length vs. number of histories", theme, "heatmap_local")
        fig_per_program(sweep, per_prog, 1024, theme, "per_program_1kbit")
        fig_per_program(sweep, per_prog, 8192, theme, "per_program_8kbit")
        fig_variants(sweep, theme, "variants")
        if q:
            fig_cost(q, theme, "cost_les_fmax")
        if bd:
            fig_breakdown(bd, theme, "mispredict_breakdown")
    print("figures in", FIGS)


if __name__ == "__main__":
    main()
