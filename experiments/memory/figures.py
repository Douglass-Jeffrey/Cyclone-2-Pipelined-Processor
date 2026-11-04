"""Figures for README.md from measured data (RTL simulation and the board).

    python experiments/memory/figures.py    -> figures/<name>.{svg,png} and <name>_dark.{svg,png}

Same style and validated palette as model/figures.py (whose helpers this imports).
"""
import csv
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "model"))
import figures as F  # noqa: E402  (model/figures.py: THEMES, style, new, titles, legend, hbar, ...)
from matplotlib.ticker import FuncFormatter  # noqa: E402

F.OUT = os.path.join(HERE, "figures")
SIM = os.path.join(HERE, "data", "sim")


def sim(tag, mode="warm"):
    return json.load(open(os.path.join(SIM, "%s_%s.json" % (tag, mode))))


# ---- figure 1: where the cycles of one clean D-cache miss go ----
# cycles per FSM phase, from dcache.v / sram_ctl.v; each row's total is the measured cost
# (dbusy / dmiss on the 19 benchmarks), which miss_phases() checks
STEPS = [("Original (WAIT_CYCLES = 2)", "base", (2, 35, 5)),
         ("WAIT_CYCLES = 1", "wait1", (2, 27, 5)),
         ("1-cycle reads, 2-cycle writes", "rd1wf", (2, 11, 5)),
         ("+ line-wide M4K port, FSM trims", "comb12", (1, 11, 0))]
PHASES = ["Miss detect, dirty check", "SRAM line transfer", "Write line into M4K + tag"]


def miss_phases():
    for name, tag, ph in STEPS:
        r = sim(tag)
        suite = [p for p in r if not p.startswith("m_")]
        cost = sum(r[p]["dbusy"] for p in suite) / sum(r[p]["dmiss"] for p in suite)
        assert abs(cost - sum(ph)) < 0.05, (name, cost, ph)


def fig_miss(t, mode):
    fig, axs = F.new(t, 8.4, 3.9)
    ax = axs[0]
    fig.subplots_adjust(left=0.31, right=0.95, top=F.top(fig, 0.95), bottom=0.15)
    F.style(ax, t, grid_axis="x")
    n = len(STEPS)
    ax.set_ylim(n - 0.5, -0.5)
    ax.set_xlim(0, 50)
    ax.set_yticks(range(n))
    ax.set_yticklabels([s for s, _, _ in STEPS], fontsize=9.5, color=t["ink"])
    gap = 0.12                                  # ~2 px surface gap between segments
    for i, (_, _, ph) in enumerate(STEPS):
        x = 0.0
        segs = [(k, v) for k, v in enumerate(ph) if v]
        for j, (k, v) in enumerate(segs):
            last = j == len(segs) - 1
            F.hbar(ax, i, x + (gap if j else 0), x + v, 18, t["s"][k], t, round_end=last)
            x += v
        ax.text(x + 0.6, i, "%d cycles" % x, va="center", ha="left", fontsize=9, color=t["ink2"])
    ax.set_xlabel("CPU cycles the pipeline is frozen, per clean data-cache miss (measured in RTL)",
                  fontsize=9, color=t["ink2"])
    F.titles(fig, t, "A data-cache miss: 42 cycles down to 12",
             "Each row keeps the changes above it.  The SRAM transfer was 83% of a miss; reads now stream one beat a cycle")
    F.legend(fig, t, [(t["s"][k], p) for k, p in enumerate(PHASES)], marker=None)
    F.save(fig, "fig_m1_miss_breakdown", mode)


# ---- figure 2: measured on the board ----
def fig_board(t, mode):
    bw = list(csv.DictReader(open(os.path.join(HERE, "data", "board", "sram_test.csv"))))
    kern = [("Original", 1342041), ("New SRAM controller", 730433), ("+ cache-side changes", 520505)]
    fig, axs = F.new(t, 9.0, 3.7, ncols=2)
    fig.subplots_adjust(left=0.17, right=0.97, top=F.top(fig, 1.05), bottom=0.17, wspace=0.62)
    labels = ["Original\n(WAIT_CYCLES = 2)", "WAIT_CYCLES = 1", "1-cycle reads,\n2-cycle writes"]
    panels = [(axs[0], labels, [float(r["mb_per_s"]) for r in bw], 60, "%.1f MB/s",
               "SRAM bandwidth (sram_test, 0 errors)", "MB/s moved through sram_ctl"),
              (axs[1], [k for k, _ in kern], [v for _, v in kern], 1.55e6, None,
               "Memory kernels (m_all), CPU cycles", "Cycles, all 16 board words = simulation")]
    for ax, names, vals, xmax, fmt, title, xlabel in panels:
        F.style(ax, t, grid_axis="x")
        ax.set_ylim(len(vals) - 0.5, -0.5)
        ax.set_xlim(0, xmax)
        ax.set_yticks(range(len(vals)))
        ax.set_yticklabels(names, fontsize=9, color=t["ink"])
        for i, v in enumerate(vals):
            F.hbar(ax, i, 0, v, 18, t["s"][0], t)
            txt = fmt % v if fmt else ("{:,}".format(v) + ("" if i == 0 else "  (%+.0f%%)" % (100.0 * (v - vals[0]) / vals[0])))
            ax.text(v + xmax * 0.015, i, txt, va="center", ha="left", fontsize=9, color=t["ink2"])
        ax.set_title(title, loc="left", fontsize=10, color=t["ink"], pad=6)
        ax.set_xlabel(xlabel, fontsize=8.5, color=t["ink2"])
    axs[0].xaxis.set_major_formatter(FuncFormatter(lambda v, _: "%g" % v))
    axs[1].xaxis.set_major_formatter(FuncFormatter(F.compact))
    F.titles(fig, t, "Measured on the DE1 at 50 MHz",
             "Left: the real SRAM chip, back-to-back line transfers.  Right: the CPU running stream, copy and pointer-chase kernels")
    F.save(fig, "fig_m2_board", mode)


# ---- figure 3: per program, final design vs original ----
def fig_programs(t, mode):
    base = {m: sim("base", m) for m in ("warm", "cold")}
    new = {m: sim("comb123", m) for m in ("warm", "cold")}
    progs = [p for p in base["warm"] if p != "m_all"]
    red = {m: {p: 100.0 * (base[m][p]["cycles"] - new[m][p]["cycles"]) / base[m][p]["cycles"] for p in progs}
           for m in ("warm", "cold")}
    progs.sort(key=lambda p: (p.startswith("m_"), -red["warm"][p]))
    fig, axs = F.new(t, 8.4, 7.4)
    ax = axs[0]
    fig.subplots_adjust(left=0.19, right=0.95, top=F.top(fig, 0.95), bottom=0.07)
    F.style(ax, t, grid_axis="x")
    n = len(progs)
    ax.set_ylim(n - 0.5, -0.5)
    ax.set_xlim(0, 75)
    ax.set_yticks(range(n))
    ax.set_yticklabels(progs, fontsize=9, color=t["ink"])
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: "%g%%" % v))
    for i, p in enumerate(progs):
        for k, (m, off) in enumerate((("warm", -0.17), ("cold", 0.17))):
            F.hbar(ax, i + off, 0, red[m][p], 7, t["s"][k], t)
        ax.text(max(red["warm"][p], red["cold"][p]) + 0.9, i, "%.0f%% / %.0f%%" % (red["warm"][p], red["cold"][p]),
                va="center", ha="left", fontsize=8, color=t["ink2"])
    ax.axhline(n - 3.5, color=t["axis"], lw=1 * F.PX)
    ax.text(74, n - 3.62, "below: memory kernels", ha="right", va="bottom", fontsize=8.5, color=t["muted"])
    sw = sum(base["warm"][p]["cycles"] for p in progs if not p.startswith("m_"))
    sn = sum(new["warm"][p]["cycles"] for p in progs if not p.startswith("m_"))
    cw = sum(base["cold"][p]["cycles"] for p in progs if not p.startswith("m_"))
    cn = sum(new["cold"][p]["cycles"] for p in progs if not p.startswith("m_"))
    ax.set_xlabel("Fewer CPU cycles than the original design (RTL simulation; labels: warm / cold)",
                  fontsize=9, color=t["ink2"])
    F.titles(fig, t, "Every program gets faster; the memory-bound ones most",
             "Final design (all changes) vs original.  19 benchmarks in total: %.1f%% warm, %.1f%% cold"
             % (100.0 * (sw - sn) / sw, 100.0 * (cw - cn) / cw))
    F.legend(fig, t, [(t["s"][0], "Code preloaded (the board today)"), (t["s"][1], "Code fetched from SRAM (with a loader)")],
             marker=None)
    F.save(fig, "fig_m3_programs", mode)


if __name__ == "__main__":
    miss_phases()
    F.plt.rcParams.update({"font.family": ["Segoe UI", "DejaVu Sans"], "svg.fonttype": "none",
                           "axes.unicode_minus": False})
    for mode, t in F.THEMES.items():
        for f in (fig_miss, fig_board, fig_programs):
            f(t, mode)
    print("figures in", F.OUT)
