"""The memory study's figures in stock matplotlib, for comparison with figures.py and
model/figures.py.

    python experiments/memory/figures_stock.py

Same data and chart types, drawn with plain matplotlib: the default style (figures/stock/,
model/figures/stock/) and plt.style.use("dark_background") (.../stock_dark/), default colors,
constrained layout, legends outside the axes.
"""
import csv
import importlib.util
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import FuncFormatter, PercentFormatter  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
STYLES = {"stock": "default", "stock_dark": "dark_background"}


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


MF = module("memory_figures", os.path.join(HERE, "figures.py"))       # STEPS, PHASES, sim()
MOD = module("model_figures", os.path.join(HERE, "model", "figures.py"))  # rows(), one(), SPEEDS, PATH, ...


def save(fig, folder, name):
    os.makedirs(folder, exist_ok=True)
    fig.savefig(os.path.join(folder, name + ".svg"))
    fig.savefig(os.path.join(folder, name + ".png"), dpi=200)
    plt.close(fig)


# ---- measured (figures.py) ----
def fig_miss(out):
    names = [s for s, _, _ in MF.STEPS]
    fig, ax = plt.subplots(figsize=(9, 3.6), layout="constrained")
    left = [0] * len(names)
    for k, phase in enumerate(MF.PHASES):
        vals = [ph[k] for _, _, ph in MF.STEPS]
        ax.barh(names, vals, left=left, label=phase)
        left = [a + b for a, b in zip(left, vals)]
    for i, total in enumerate(left):
        ax.text(total + 0.5, i, "%d cycles" % total, va="center")
    ax.invert_yaxis()
    ax.set_xlim(0, 52)
    ax.set_xlabel("CPU cycles frozen per clean data-cache miss (RTL)")
    ax.set_title("A data-cache miss: 42 cycles down to 12")
    fig.legend(loc="outside right upper")
    save(fig, out, "fig_m1_miss_breakdown")


def fig_board(out):
    bw = list(csv.DictReader(open(os.path.join(HERE, "data", "board", "sram_test.csv"))))
    fig, axes = plt.subplots(1, 2, figsize=(10, 3.4), layout="constrained")
    names = ["Original (WAIT=2)", "WAIT_CYCLES=1", "1-cycle reads,\n2-cycle writes"]
    bars = axes[0].barh(names, [float(r["mb_per_s"]) for r in bw])
    axes[0].bar_label(bars, fmt="%.1f MB/s", padding=3)
    axes[0].set_xlim(0, 65)
    axes[0].set_xlabel("MB/s through sram_ctl")
    axes[0].set_title("SRAM bandwidth (sram_test, 0 errors)")
    kern = [("Original", 1342041), ("New SRAM controller", 730433), ("+ cache-side changes", 520505)]
    bars = axes[1].barh([k for k, _ in kern], [v for _, v in kern])
    axes[1].bar_label(bars, labels=["{:,}".format(v) for _, v in kern], padding=3)
    axes[1].set_xlim(0, 1.7e6)
    axes[1].xaxis.set_major_formatter(FuncFormatter(lambda v, _: "%gM" % (v / 1e6)))
    axes[1].set_xlabel("CPU cycles")
    axes[1].set_title("Memory kernels (m_all) on the CPU")
    for a in axes:
        a.invert_yaxis()
    fig.suptitle("Measured on the DE1 at 50 MHz")
    save(fig, out, "fig_m2_board")


def fig_programs(out):
    base = {m: MF.sim("base", m) for m in ("warm", "cold")}
    new = {m: MF.sim("comb123", m) for m in ("warm", "cold")}
    progs = [p for p in base["warm"] if p != "m_all"]
    red = {m: [100.0 * (base[m][p]["cycles"] - new[m][p]["cycles"]) / base[m][p]["cycles"] for p in progs]
           for m in ("warm", "cold")}
    order = sorted(range(len(progs)), key=lambda i: (progs[i].startswith("m_"), -red["warm"][i]))
    progs = [progs[i] for i in order]
    fig, ax = plt.subplots(figsize=(9, 7.4), layout="constrained")
    y = range(len(progs))
    ax.barh([i - 0.2 for i in y], [red["warm"][i] for i in order], height=0.4, label="Code preloaded (board today)")
    ax.barh([i + 0.2 for i in y], [red["cold"][i] for i in order], height=0.4, label="Code fetched from SRAM")
    ax.set_yticks(list(y), progs)
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(PercentFormatter(decimals=0))
    ax.set_xlabel("Fewer CPU cycles than the original design (RTL simulation)")
    ax.set_title("Final design vs original, per program")
    ax.grid(True, axis="x", alpha=0.3)
    fig.legend(loc="outside right upper")
    save(fig, out, "fig_m3_programs")


# ---- model (model/figures.py) ----
def fig_speed(out):
    S = MOD.rows("summary_dcache.csv")
    lines = (16, 32, 64)
    fig, axes = plt.subplots(1, 2, figsize=(10, 4.4), sharey=True, layout="constrained")
    for ax, port, title in zip(axes, ("32", "line"), ("32-bit fill port (today)", "Line-wide fill port")):
        for sp, name in MOD.SPEEDS:
            ys = [float(MOD.one(S, size=16384, line=l, ways=1, wv=0, port=port, speed=sp)["stall_pct"]) for l in lines]
            ax.plot(lines, ys, "o-", label=name if port == "32" else None)
        ax.set_xscale("log", base=2)
        ax.set_xticks(lines, ["%d B" % l for l in lines])
        ax.minorticks_off()
        ax.yaxis.set_major_formatter(PercentFormatter(decimals=0))
        ax.set_xlabel("Cache line size")
        ax.set_title(title)
        ax.grid(True, alpha=0.3)
    axes[0].set_ylabel("Memory stall, % of all cycles")
    fig.suptitle("SRAM controller speed matters more than cache shape (16 KB D-cache, model)")
    fig.legend(loc="outside right upper")
    save(fig, out, "fig1_controller_speed")


def fig_assoc(out):
    S, Pp = MOD.rows("summary_dcache.csv"), MOD.rows("per_program.csv")
    lines = (16, 32, 64)
    panels = [("19 benchmarks", None), ("m_stream", "m_stream"), ("m_copy", "m_copy"), ("m_chase", "m_chase")]
    fig, axes = plt.subplots(1, 4, figsize=(13, 3.8), layout="constrained")
    for ax, (title, prog) in zip(axes, panels):
        for w in (1, 2, 4):
            if prog is None:
                ys = [int(MOD.one(S, size=16384, line=l, ways=w, wv=0, port=32, speed="today")["miss"]) for l in lines]
            else:
                ys = [int(MOD.one(Pp, program=prog, size=16384, line=l, ways=w, wv=0, port=32, speed="today")["miss"])
                      for l in lines]
            ax.plot(lines, ys, "o-", label=("direct mapped" if w == 1 else "%d-way LRU" % w) if prog is None else None)
        ax.set_xscale("log", base=2)
        ax.set_xticks(lines, [str(l) for l in lines])
        ax.minorticks_off()
        ax.set_ylim(bottom=0)
        ax.set_xlabel("Line size (B)")
        ax.set_title(title)
        ax.grid(True, alpha=0.3)
    axes[0].set_ylabel("Data-cache misses")
    fig.suptitle("Associativity only helps when two buffers fight over one index\n"
                 "(model; the lines coincide where the number of ways makes no difference)")
    fig.legend(loc="outside right upper")
    save(fig, out, "fig2_associativity")


def fig_path(out):
    S = MOD.rows("summary_dcache.csv")
    vals = [MOD.one(S, size=16384, ways=1, **kw) for _, kw in MOD.PATH]
    fig, ax = plt.subplots(figsize=(9, 4), layout="constrained")
    bars = ax.barh([n for n, _ in MOD.PATH], [int(r["stall"]) for r in vals])
    ax.bar_label(bars, labels=["{:,}  ({:.2f}%)".format(int(r["stall"]), float(r["stall_pct"])) for r in vals], padding=3)
    ax.invert_yaxis()
    ax.set_xlim(0, 220000)
    ax.set_xlabel("Data-cache stall cycles, 19 benchmarks (model)")
    ax.set_title("Memory stall cycles, one change at a time")
    save(fig, out, "fig3_path")


def fig_programs_model(out):
    Pp = MOD.rows("per_program.csv")
    pts = MOD.POINTS
    progs = sorted({r["program"] for r in Pp}, key=lambda n: (
        n.startswith("m_"), -float(MOD.one(Pp, program=n, size=16384, ways=1, **pts[0][1])["stall_pct"])))
    fig, ax = plt.subplots(figsize=(9, 7.4), layout="constrained")
    for name, kw in pts:
        xs = [float(MOD.one(Pp, program=n, size=16384, ways=1, **kw)["stall_pct"]) for n in progs]
        ax.plot(xs, range(len(progs)), "o", label=name)
    ax.set_yticks(range(len(progs)), progs)
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(PercentFormatter(decimals=0))
    ax.set_xlabel("Data-cache stall, % of the program's cycles (model)")
    ax.set_title("Where the time goes, program by program")
    ax.grid(True, axis="x", alpha=0.3)
    fig.legend(loc="outside right upper")
    save(fig, out, "fig4_per_program")


def fig_cold(out):
    C = MOD.rows("summary_cold.csv")
    vals = [MOD.one(C, isize=8192, iways=1, **kw) for _, kw in MOD.COLD]
    names = [c for c, _ in MOD.COLD]
    ip = [100 * float(r["istall"]) / float(r["cycles"]) for r in vals]
    dp = [100 * float(r["dstall"]) / float(r["cycles"]) for r in vals]
    fig, ax = plt.subplots(figsize=(9, 3.6), layout="constrained")
    ax.barh(names, ip, label="instruction-cache stall")
    bars = ax.barh(names, dp, left=ip, label="data-cache stall")
    ax.bar_label(bars, labels=["%.1f%%" % (a + b) for a, b in zip(ip, dp)], padding=3)
    ax.invert_yaxis()
    ax.set_xlim(0, 11)
    ax.xaxis.set_major_formatter(PercentFormatter(decimals=0))
    ax.set_xlabel("Memory stall, % of all cycles (19 benchmarks, code from SRAM, model)")
    ax.set_title("With a loader, instruction misses cost as much as data misses")
    fig.legend(loc="outside right upper")
    save(fig, out, "fig5_cold_start")


if __name__ == "__main__":
    for folder, style in STYLES.items():
        with plt.style.context(style):
            for f in (fig_miss, fig_board, fig_programs):
                f(os.path.join(HERE, "figures", folder))
            for f in (fig_speed, fig_assoc, fig_path, fig_programs_model, fig_cold):
                f(os.path.join(HERE, "model", "figures", folder))
    print("figures in figures/stock*, model/figures/stock*")
