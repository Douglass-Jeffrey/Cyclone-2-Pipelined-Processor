#!/usr/bin/env python3
"""The memory study's figures, from measured data (data/) and the cache model (model/data/).

    python experiments/memory/figures.py

Writes figures/plain*/ (measured: RTL simulation and the board) and model/figures/plain*/ (model),
in matplotlib's default style (plain/) and dark_background (plain_dark/).
"""
import csv
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.ticker import PercentFormatter  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(HERE, "data", "sim")
MODEL_DATA = os.path.join(HERE, "model", "data")
STYLES = {"plain": "default", "plain_dark": "dark_background"}
OUT_MEASURED = OUT_MODEL = None  # set per style in __main__

# cycles per FSM phase of one clean D-cache miss, from dcache.v / sram_ctl.v; each row's total is
# the measured cost (dbusy / dmiss on the 19 benchmarks), which miss_phases() checks
STEPS = [("Original (WAIT_CYCLES = 2)", "base", (2, 35, 5)),
         ("WAIT_CYCLES = 1", "wait1", (2, 27, 5)),
         ("1-cycle reads, 2-cycle writes", "rd1wf", (2, 11, 5)),
         ("+ line-wide M4K port, FSM trims", "comb12", (1, 11, 0))]
PHASES = ["Miss detect, dirty check", "SRAM line transfer", "Write line into M4K + tag"]

# model design points (model/data/*.csv keys)
SPEEDS = [("today", "Today: 4 cycles a beat"), ("wait1", "WAIT_CYCLES = 1: 3 cycles a beat"),
          ("burst", "Burst reads: 1 cycle a beat")]
PATH = [
    ("Today (42-cycle miss)", dict(line=16, wv=0, port=32, speed="today")),
    ("WAIT_CYCLES = 1", dict(line=16, wv=0, port=32, speed="wait1")),
    ("Burst reads, 1 cycle a beat", dict(line=16, wv=0, port=32, speed="burst")),
    ("+ line-wide fill port", dict(line=16, wv=0, port="line", speed="burst")),
    ("+ 32-byte lines", dict(line=32, wv=0, port="line", speed="burst")),
    ("+ write-validate", dict(line=32, wv=1, port="line", speed="burst")),
]
POINTS = [("Today", dict(line=16, wv=0, port=32, speed="today")),
          ("Burst reads only", dict(line=16, wv=0, port=32, speed="burst")),
          ("Burst + wide port + 32 B lines + write-validate", dict(line=32, wv=1, port="line", speed="burst"))]
COLD = [("Today", dict(iline=16, port=32, speed="today")),
        ("Burst reads", dict(iline=16, port=32, speed="burst")),
        ("Burst + wide port + 32 B lines", dict(iline=32, port="line", speed="burst")),
        ("Burst + wide port + 64 B lines", dict(iline=64, port="line", speed="burst"))]


# ---- data ---------------------------------------------------------------------
def sim(tag, mode="warm"):
    return json.load(open(os.path.join(SIM, "%s_%s.json" % (tag, mode))))


def miss_phases():
    for name, tag, ph in STEPS:
        r = sim(tag)
        suite = [p for p in r if not p.startswith("m_")]
        cost = sum(r[p]["dbusy"] for p in suite) / sum(r[p]["dmiss"] for p in suite)
        assert abs(cost - sum(ph)) < 0.05, (name, cost, ph)


def rows(name):
    return list(csv.DictReader(open(os.path.join(MODEL_DATA, name))))


def one(rs, **kw):
    m = [r for r in rs if all(r[k] == str(v) for k, v in kw.items())]
    assert len(m) == 1, (kw, len(m))
    return m[0]


# ---- figures ------------------------------------------------------------------
def save(fig, folder, name):
    os.makedirs(folder, exist_ok=True)
    fig.tight_layout()
    fig.savefig(os.path.join(folder, name + ".svg"))
    fig.savefig(os.path.join(folder, name + ".png"), dpi=150)
    plt.close(fig)


# measured
def fig_miss():
    names = [s for s, _, _ in STEPS]
    fig, ax = plt.subplots(figsize=(9, 4))
    left = np.zeros(len(names))
    for k, phase in enumerate(PHASES):
        vals = np.array([ph[k] for _, _, ph in STEPS])
        ax.barh(names, vals, left=left, label=phase)
        left += vals
    for i, total in enumerate(left):
        ax.text(total + 0.5, i, "%d" % total, va="center")
    ax.invert_yaxis()
    ax.set_xlim(0, 50)
    ax.set_xlabel("CPU cycles per clean data-cache miss (RTL)")
    ax.set_title("Data-cache miss cost")
    ax.legend(loc="lower right")
    save(fig, OUT_MEASURED, "fig_m1_miss_breakdown")


def fig_board():
    bw = list(csv.DictReader(open(os.path.join(HERE, "data", "board", "sram_test.csv"))))
    kern = [("Original", 1342041), ("New SRAM controller", 730433), ("+ cache-side changes", 520505)]
    fig, axes = plt.subplots(1, 2, figsize=(11, 3.5))
    names = ["Original (WAIT=2)", "WAIT_CYCLES=1", "1-cycle reads,\n2-cycle writes"]
    bars = axes[0].barh(names, [float(r["mb_per_s"]) for r in bw])
    axes[0].bar_label(bars, fmt="%.1f", padding=3)
    axes[0].set_xlim(0, 65)
    axes[0].set_xlabel("MB/s")
    axes[0].set_title("SRAM bandwidth (sram_test)")
    bars = axes[1].barh([k for k, _ in kern], [v / 1e6 for _, v in kern])
    axes[1].bar_label(bars, labels=["{:,}".format(v) for _, v in kern], padding=3)
    axes[1].set_xlim(0, 1.7)
    axes[1].set_xlabel("CPU cycles (millions)")
    axes[1].set_title("Memory kernels (m_all)")
    for a in axes:
        a.invert_yaxis()
    fig.suptitle("Measured on the DE1 at 50 MHz")
    save(fig, OUT_MEASURED, "fig_m2_board")


def fig_programs():
    base = {m: sim("base", m) for m in ("warm", "cold")}
    new = {m: sim("comb123", m) for m in ("warm", "cold")}
    progs = [p for p in base["warm"] if p != "m_all"]
    red = {m: {p: 100.0 * (base[m][p]["cycles"] - new[m][p]["cycles"]) / base[m][p]["cycles"] for p in progs}
           for m in ("warm", "cold")}
    progs.sort(key=lambda p: (p.startswith("m_"), -red["warm"][p]))
    y = np.arange(len(progs))
    fig, ax = plt.subplots(figsize=(9, 7.5))
    ax.barh(y - 0.2, [red["warm"][p] for p in progs], 0.4, label="Code preloaded (board today)")
    ax.barh(y + 0.2, [red["cold"][p] for p in progs], 0.4, label="Code fetched from SRAM")
    ax.set_yticks(y, progs)
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(PercentFormatter(decimals=0))
    ax.set_xlabel("Cycle reduction vs. original design (RTL simulation)")
    ax.set_title("Final design vs. original, per program")
    ax.grid(True, axis="x")
    ax.legend(loc="center right")
    save(fig, OUT_MEASURED, "fig_m3_programs")


# model
def fig_speed():
    S = rows("summary_dcache.csv")
    lines = (16, 32, 64)
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.5), sharey=True)
    for ax, port, title in zip(axes, ("32", "line"), ("32-bit fill port (today)", "Line-wide fill port")):
        for sp, name in SPEEDS:
            ys = [float(one(S, size=16384, line=l, ways=1, wv=0, port=port, speed=sp)["stall_pct"]) for l in lines]
            ax.plot(lines, ys, "o-", label=name)
        ax.set_xscale("log", base=2)
        ax.set_xticks(lines, ["%d B" % l for l in lines])
        ax.minorticks_off()
        ax.yaxis.set_major_formatter(PercentFormatter(decimals=1))
        ax.set_xlabel("Cache line size")
        ax.set_title(title)
        ax.grid(True)
    axes[0].legend()
    axes[0].set_ylabel("Memory stall, % of cycles")
    fig.suptitle("SRAM controller speed vs. line size (16 KB D-cache, model)")
    save(fig, OUT_MODEL, "fig1_controller_speed")


def fig_assoc():
    S, Pp = rows("summary_dcache.csv"), rows("per_program.csv")
    lines = (16, 32, 64)
    panels = [("19 benchmarks", None), ("m_stream", "m_stream"), ("m_copy", "m_copy"), ("m_chase", "m_chase")]
    fig, axes = plt.subplots(1, 4, figsize=(14, 4))
    for ax, (title, prog) in zip(axes, panels):
        for w, fmt in ((1, "o-"), (2, "s--"), (4, "^:")):
            kw = dict(size=16384, line=None, ways=w, wv=0, port=32, speed="today")
            if prog is not None:
                kw["program"] = prog
            src = S if prog is None else Pp
            ys = [int(one(src, **dict(kw, line=l))["miss"]) for l in lines]
            ax.plot(lines, ys, fmt, label="direct mapped" if w == 1 else "%d-way LRU" % w)
        ax.set_xscale("log", base=2)
        ax.set_xticks(lines, [str(l) for l in lines])
        ax.minorticks_off()
        ax.set_ylim(bottom=0)
        ax.set_xlabel("Line size (B)")
        ax.set_title(title)
        ax.grid(True)
    axes[0].set_ylabel("Data-cache misses")
    axes[0].legend()
    fig.suptitle("Data-cache misses vs. associativity (16 KB, model)")
    save(fig, OUT_MODEL, "fig2_associativity")


def fig_path():
    S = rows("summary_dcache.csv")
    vals = [one(S, size=16384, ways=1, **kw) for _, kw in PATH]
    fig, ax = plt.subplots(figsize=(9, 4))
    bars = ax.barh([n for n, _ in PATH], [int(r["stall"]) for r in vals])
    ax.bar_label(bars, labels=["{:,} ({:.2f}%)".format(int(r["stall"]), float(r["stall_pct"])) for r in vals],
                 padding=3)
    ax.invert_yaxis()
    ax.set_xlim(0, 220000)
    ax.set_xlabel("Data-cache stall cycles, 19 benchmarks (model)")
    ax.set_title("Memory stall cycles, one change at a time")
    save(fig, OUT_MODEL, "fig3_path")


def fig_programs_model():
    Pp = rows("per_program.csv")
    pts = POINTS
    progs = sorted({r["program"] for r in Pp}, key=lambda n: (
        n.startswith("m_"), -float(one(Pp, program=n, size=16384, ways=1, **pts[0][1])["stall_pct"])))
    y = np.arange(len(progs))
    h = 0.8 / len(pts)
    fig, ax = plt.subplots(figsize=(9, 8))
    for k, (name, kw) in enumerate(pts):
        xs = [float(one(Pp, program=n, size=16384, ways=1, **kw)["stall_pct"]) for n in progs]
        ax.barh(y + (k - (len(pts) - 1) / 2) * h, xs, h, label=name)
    ax.set_yticks(y, progs)
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(PercentFormatter(decimals=0))
    ax.set_xlabel("Data-cache stall, % of the program's cycles (model)")
    ax.set_title("Data-cache stall per program")
    ax.grid(True, axis="x")
    ax.legend(loc="center right")
    save(fig, OUT_MODEL, "fig4_per_program")


def fig_cold():
    C = rows("summary_cold.csv")
    vals = [one(C, isize=8192, iways=1, **kw) for _, kw in COLD]
    names = [c for c, _ in COLD]
    ip = [100 * float(r["istall"]) / float(r["cycles"]) for r in vals]
    dp = [100 * float(r["dstall"]) / float(r["cycles"]) for r in vals]
    fig, ax = plt.subplots(figsize=(9, 4))
    ax.barh(names, ip, label="I-cache stall")
    bars = ax.barh(names, dp, left=ip, label="D-cache stall")
    ax.bar_label(bars, labels=["%.1f%%" % (a + b) for a, b in zip(ip, dp)], padding=3)
    ax.invert_yaxis()
    ax.set_xlim(0, 11)
    ax.xaxis.set_major_formatter(PercentFormatter(decimals=0))
    ax.set_xlabel("Memory stall, % of cycles (19 benchmarks, code from SRAM, model)")
    ax.set_title("Instruction vs. data cache stall with a loader")
    ax.legend(loc="lower right")
    save(fig, OUT_MODEL, "fig5_cold_start")


if __name__ == "__main__":
    miss_phases()
    for folder, style in STYLES.items():
        OUT_MEASURED = os.path.join(HERE, "figures", folder)
        OUT_MODEL = os.path.join(HERE, "model", "figures", folder)
        with plt.style.context(style):
            for f in (fig_miss, fig_board, fig_programs, fig_speed, fig_assoc, fig_path, fig_programs_model, fig_cold):
                f()
    print("figures in figures/plain*, model/figures/plain*")
