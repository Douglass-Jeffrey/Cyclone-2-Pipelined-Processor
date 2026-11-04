"""Figures for findings.md from data/*.csv -> figures/<name>.{svg,png} and <name>_dark.{svg,png}

    python experiments/memory/model/figures.py

Colors are the dataviz reference palette's first three categorical slots, validated
all-pairs in both modes (worst CVD dE 9.2 light / 9.4 dark).  Light aqua is under 3:1 on
the light surface, so every aqua series carries a direct label; the CSVs are the table view.
"""
import csv
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Patch, PathPatch, Rectangle  # noqa: E402
from matplotlib.path import Path  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "figures")

THEMES = {
    "light": dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e", muted="#898781",
                  grid="#e1e0d9", axis="#c3c2b7", s=["#2a78d6", "#eb6834", "#1baf7a"]),
    "dark": dict(surface="#1a1a19", ink="#f0efec", ink2="#c3c2b7", muted="#898781",
                 grid="#2c2c2a", axis="#383835", s=["#3987e5", "#d95926", "#199e70"]),
}
PX = 0.75   # points per pixel at 96 dpi
LW, MS, RING = 2 * PX, 8 * PX, 2 * PX
SPEEDS = [("today", "Today: 4 cycles a beat"), ("wait1", "WAIT_CYCLES = 1: 3 cycles a beat"),
          ("burst", "Burst reads: 1 cycle a beat")]


def rows(name):
    return list(csv.DictReader(open(os.path.join(DATA, name))))


def pick(rs, **kw):
    return [r for r in rs if all(r[k] == str(v) for k, v in kw.items())]


def one(rs, **kw):
    m = pick(rs, **kw)
    assert len(m) == 1, (kw, len(m))
    return m[0]


def axis_fmt(vmax):
    """One tick style per axis: compact once the axis reaches 10,000."""
    return FuncFormatter(lambda v, _: "0" if v == 0 else ("%gK" % (v / 1000)) if vmax >= 1e4 else "{:,.0f}".format(v))


def compact(v, _=None):
    v = float(v)
    if abs(v) >= 1e6:
        return "%gM" % round(v / 1e6, 2)
    if abs(v) >= 1e4:
        return "%gK" % round(v / 1e3, 1)
    return "{:,.0f}".format(v)


def style(ax, t, grid_axis="y"):
    ax.set_facecolor(t["surface"])
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(t["axis"])
    ax.spines["bottom"].set_linewidth(1 * PX)
    ax.tick_params(colors=t["muted"], labelcolor=t["ink2"], length=0, labelsize=9)
    ax.grid(axis=grid_axis, color=t["grid"], linewidth=1 * PX, linestyle="-")
    ax.set_axisbelow(True)
    if grid_axis == "x":
        ax.spines["bottom"].set_visible(False)
        ax.spines["left"].set_visible(True)
        ax.spines["left"].set_color(t["axis"])
        ax.spines["left"].set_linewidth(1 * PX)


def new(t, w=8.0, h=4.6, ncols=1, sharey=False):
    fig, axs = plt.subplots(1, ncols, figsize=(w, h), sharey=sharey, squeeze=False)
    fig.patch.set_facecolor(t["surface"])
    return fig, axs[0]


def titles(fig, t, title, sub):
    """Title block anchored in inches from the top, so it holds at any figure height."""
    h = fig.get_figheight()
    fig.text(0.012, 1 - 0.16 / h, title, ha="left", va="top", fontsize=13, fontweight="semibold", color=t["ink"])
    fig.text(0.012, 1 - 0.47 / h, sub, ha="left", va="top", fontsize=9.5, color=t["ink2"])


def top(fig, inches):
    """subplots_adjust top that leaves `inches` for the title block (and legend)."""
    return 1 - inches / fig.get_figheight()


def legend(fig, t, entries, marker="o"):
    """Standard legend outside the rightmost axes: line+marker keys, or patches for bars (marker=None)."""
    handles = [plt.Line2D([], [], color=c, lw=LW, marker=marker, ms=MS * 0.8, mew=0)
               if marker else Patch(facecolor=c, edgecolor="none") for c, _ in entries]
    ax = max(fig.axes, key=lambda a: a.get_position().x1)
    ax.legend(handles, [n for _, n in entries], loc="upper left", bbox_to_anchor=(1.02, 1), borderaxespad=0,
              fontsize=9, labelcolor=t["ink2"], facecolor=t["surface"], edgecolor=t["axis"], framealpha=1)


def save(fig, name, mode):
    os.makedirs(OUT, exist_ok=True)
    stem = os.path.join(OUT, name + ("" if mode == "light" else "_dark"))
    fig.savefig(stem + ".svg", facecolor=fig.get_facecolor(), bbox_inches="tight", pad_inches=0.2)
    fig.savefig(stem + ".png", dpi=200, facecolor=fig.get_facecolor(), bbox_inches="tight", pad_inches=0.2)
    plt.close(fig)


def hbar(ax, y, x0, x1, thick_px, color, t, round_end=True):
    """Horizontal bar from x0 to x1: 4px rounded data end, square at the baseline."""
    fig = ax.figure
    fig.canvas.draw()
    bb = ax.get_window_extent()
    (xa, xb), (ya, yb) = ax.get_xlim(), ax.get_ylim()
    xpp = (xb - xa) / bb.width          # data units per pixel
    ypp = abs(yb - ya) / bb.height
    h = thick_px * ypp
    if x1 - x0 <= 0:
        return
    if not round_end:
        ax.add_patch(Rectangle((x0, y - h / 2), x1 - x0, h, color=color, lw=0))
        return
    # one path: square at x0, quarter-circle corners of 4px at x1 (cubic Bezier, k = 0.5523)
    rx, ry = min(4 * xpp, (x1 - x0) / 2), min(4 * ypp, h / 2)
    k = 0.5523
    y0, y1 = y - h / 2, y + h / 2
    verts = [(x0, y0), (x1 - rx, y0),
             (x1 - rx + k * rx, y0), (x1, y0 + ry - k * ry), (x1, y0 + ry),
             (x1, y1 - ry),
             (x1, y1 - ry + k * ry), (x1 - rx + k * rx, y1), (x1 - rx, y1),
             (x0, y1), (x0, y0)]
    codes = [Path.MOVETO, Path.LINETO, Path.CURVE4, Path.CURVE4, Path.CURVE4, Path.LINETO,
             Path.CURVE4, Path.CURVE4, Path.CURVE4, Path.LINETO, Path.CLOSEPOLY]
    ax.add_patch(PathPatch(Path(verts, codes), facecolor=color, lw=0))


# ---- figure 1: stall vs line size for the three controller speeds, both fill ports ----
def fig_speed(t, mode):
    S = rows("summary_dcache.csv")
    fig, axs = new(t, 8.6, 4.8, ncols=2, sharey=True)
    lines = (16, 32, 64)
    for ax, port, label in zip(axs, ("32", "line"), ("32-bit fill port (today)", "Line-wide fill port")):
        style(ax, t)
        for k, (sp, name) in enumerate(SPEEDS):
            ys = [float(one(S, size=16384, line=l, ways=1, wv=0, port=port, speed=sp)["stall_pct"]) for l in lines]
            ax.plot(lines, ys, color=t["s"][k], lw=LW, marker="o", ms=MS, mec=t["surface"], mew=RING,
                    solid_capstyle="round", zorder=3)
            ax.text(64 * 1.08, ys[-1], "%.1f%%" % ys[-1], va="center", ha="left", fontsize=9, color=t["ink2"])
        ax.set_xscale("log", base=2)
        ax.set_xticks(lines)
        ax.set_xticklabels(["%d B" % l for l in lines])
        ax.set_xlim(13, 90)
        ax.set_ylim(0, 4.8)
        ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: "%g%%" % v))
        ax.set_title(label, loc="left", fontsize=10, color=t["ink"], pad=6)
        ax.set_xlabel("Cache line size", fontsize=9, color=t["ink2"])
    axs[0].set_ylabel("Memory stall, % of all cycles", fontsize=9, color=t["ink2"])
    titles(fig, t, "SRAM controller speed matters more than cache shape",
           "16 KB direct-mapped data cache, 19 benchmarks, code preloaded (as on the board)")
    legend(fig, t, [(t["s"][k], n) for k, (_, n) in enumerate(SPEEDS)])
    fig.subplots_adjust(left=0.08, right=0.95, top=top(fig, 1.0), bottom=0.13, wspace=0.12)
    save(fig, "fig1_controller_speed", mode)


# ---- figure 2: misses vs line size for 1/2/4 ways, suite and the three kernels ----
def fig_assoc(t, mode):
    S = rows("summary_dcache.csv")
    P = rows("per_program.csv")
    fig, axs = new(t, 9.2, 4.6, ncols=4)
    lines = (16, 32, 64)
    panels = [("19 benchmarks", None), ("m_stream (32 KB array)", "m_stream"),
              ("m_copy (16 KB apart)", "m_copy"), ("m_chase (64 KB list)", "m_chase")]
    for ax, (label, prog) in zip(axs, panels):
        style(ax, t)
        for k, w in enumerate((1, 2, 4)):
            if prog is None:
                ys = [int(one(S, size=16384, line=l, ways=w, wv=0, port=32, speed="today")["miss"]) for l in lines]
            else:
                ys = [int(one(P, program=prog, size=16384, line=l, ways=w, wv=0, port=32, speed="today")["miss"])
                      for l in lines]
            ax.plot(lines, ys, color=t["s"][k], lw=LW, marker="o", ms=MS, mec=t["surface"], mew=RING, zorder=3 + k)
        ax.set_xscale("log", base=2)
        ax.set_xticks(lines)
        ax.set_xticklabels(["%d" % l for l in lines])
        ax.set_xlim(13, 78)
        ax.set_ylim(bottom=0)
        ax.yaxis.set_major_formatter(axis_fmt(ax.get_ylim()[1]))
        ax.set_title(label, loc="left", fontsize=9.5, color=t["ink"], pad=6)
        note = {None: "all three identical", "m_stream": "all three identical",
                "m_chase": "all three within 1%", "m_copy": None}[prog]
        if note:
            ax.text(0.95, 0.95, note, transform=ax.transAxes, ha="right", va="top", fontsize=8.5, color=t["ink2"])
        if prog == "m_copy":
            ax.text(0.5, 0.86, "direct mapped", transform=ax.transAxes, ha="center", va="bottom",
                    fontsize=8.5, color=t["ink2"])
            ax.text(0.62, 0.30, "2- and 4-way identical", transform=ax.transAxes, ha="center", va="bottom",
                    fontsize=8.5, color=t["ink2"])
        ax.set_xlabel("Line size (B)", fontsize=8.5, color=t["ink2"])
    axs[0].set_ylabel("Data-cache misses", fontsize=9, color=t["ink2"])
    titles(fig, t, "Associativity only helps when two buffers fight over one index",
           "16 KB data cache; the benchmarks' misses are first touches, so only line size moves them")
    legend(fig, t, [(t["s"][0], "direct mapped"), (t["s"][1], "2-way LRU"), (t["s"][2], "4-way LRU")])
    fig.subplots_adjust(left=0.07, right=0.985, top=top(fig, 1.0), bottom=0.13, wspace=0.42)
    save(fig, "fig2_associativity", mode)


# ---- figure 3: the step-by-step path for the suite ----
PATH = [
    ("Today (42-cycle miss)", dict(line=16, wv=0, port=32, speed="today")),
    ("WAIT_CYCLES = 1", dict(line=16, wv=0, port=32, speed="wait1")),
    ("Burst reads, 1 cycle a beat", dict(line=16, wv=0, port=32, speed="burst")),
    ("+ line-wide fill port", dict(line=16, wv=0, port="line", speed="burst")),
    ("+ 32-byte lines", dict(line=32, wv=0, port="line", speed="burst")),
    ("+ write-validate", dict(line=32, wv=1, port="line", speed="burst")),
]


def fig_path(t, mode):
    S = rows("summary_dcache.csv")
    vals = [one(S, size=16384, ways=1, **kw) for _, kw in PATH]
    fig, axs = new(t, 8.2, 4.4)
    ax = axs[0]
    fig.subplots_adjust(left=0.30, right=0.97, top=top(fig, 0.95), bottom=0.13)
    style(ax, t, grid_axis="x")
    n = len(PATH)
    ax.set_ylim(n - 0.5, -0.5)
    xmax = 215000
    ax.set_xlim(0, xmax)
    ax.set_yticks(range(n))
    ax.set_yticklabels([p for p, _ in PATH], fontsize=9.5, color=t["ink"])
    ax.xaxis.set_major_formatter(FuncFormatter(compact))
    for i, r in enumerate(vals):
        v = int(r["stall"])
        hbar(ax, i, 0, v, 18, t["s"][0], t)
        ax.text(v + xmax * 0.012, i, "%s  \u00b7  %.2f%%" % ("{:,}".format(v), float(r["stall_pct"])),
                va="center", ha="left", fontsize=9, color=t["ink2"])
    ax.set_xlabel("Data-cache stall cycles, 19 benchmarks", fontsize=9, color=t["ink2"])
    titles(fig, t, "Memory stall cycles, one change at a time",
           "Each step keeps the ones above it; labels give cycles and % of all cycles.  The last design fits 51 of 52 M4Ks")
    save(fig, "fig3_path", mode)


# ---- figure 4: per program, three design points ----
POINTS = [("Today", dict(line=16, wv=0, port=32, speed="today")),
          ("Burst reads only", dict(line=16, wv=0, port=32, speed="burst")),
          ("Burst + wide port + 32 B lines + write-validate", dict(line=32, wv=1, port="line", speed="burst"))]


def fig_programs(t, mode):
    P = rows("per_program.csv")
    progs = sorted({r["program"] for r in P},
                   key=lambda n: (n.startswith("m_"),
                                  -float(one(P, program=n, size=16384, ways=1, **POINTS[0][1])["stall_pct"])))
    fig, axs = new(t, 8.2, 7.6)
    ax = axs[0]
    style(ax, t, grid_axis="x")
    ax.set_ylim(len(progs) - 0.4, -0.6)
    ax.set_xlim(0, 100)
    ax.set_yticks(range(len(progs)))
    ax.set_yticklabels(progs, fontsize=9, color=t["ink"])
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: "%g%%" % v))
    split = sum(1 for p in progs if not p.startswith("m_")) - 0.5
    ax.axhline(split, color=t["axis"], lw=1 * PX)
    ax.text(30, split + 0.12, "memory kernels", ha="left", va="top", fontsize=8.5, color=t["muted"])
    for i, n in enumerate(progs):
        xs = [float(one(P, program=n, size=16384, ways=1, **kw)["stall_pct"]) for _, kw in POINTS]
        ax.plot([min(xs), max(xs)], [i, i], color=t["grid"], lw=LW, zorder=2, solid_capstyle="round")
        for k, x in enumerate(xs):
            ax.plot([x], [i], "o", color=t["s"][k], ms=MS, mec=t["surface"], mew=RING, zorder=3 + k)
    # direct labels on the top row only (legend carries the rest)
    first = [float(one(P, program=progs[0], size=16384, ways=1, **kw)["stall_pct"]) for _, kw in POINTS]
    for k, x in enumerate(first):
        ax.annotate("%.0f%%" % x, (x, 0), xytext=(0, 9), textcoords="offset points", ha="center",
                    fontsize=8.5, color=t["ink2"])
    ax.set_xlabel("Data-cache stall, % of the program's cycles", fontsize=9, color=t["ink2"])
    titles(fig, t, "Where the time goes, program by program",
           "Small programs are dominated by first-touch misses; the combined design removes most of them")
    legend(fig, t, [(t["s"][k], n) for k, (n, _) in enumerate(POINTS)], marker="o")
    fig.subplots_adjust(left=0.17, right=0.97, top=top(fig, 0.95), bottom=0.07)
    save(fig, "fig4_per_program", mode)


# ---- figure 5: cold start, I-cache vs D-cache stall ----
COLD = [("Today", dict(iline=16, port=32, speed="today")),
        ("Burst reads", dict(iline=16, port=32, speed="burst")),
        ("Burst + wide port + 32 B lines", dict(iline=32, port="line", speed="burst")),
        ("Burst + wide port + 64 B lines", dict(iline=64, port="line", speed="burst"))]


def fig_cold(t, mode):
    C = rows("summary_cold.csv")
    vals = [one(C, isize=8192, iways=1, **kw) for _, kw in COLD]
    fig, axs = new(t, 8.2, 3.9)
    ax = axs[0]
    fig.subplots_adjust(left=0.30, right=0.97, top=top(fig, 0.95), bottom=0.15)
    style(ax, t, grid_axis="x")
    n = len(COLD)
    ax.set_ylim(n - 0.5, -0.5)
    ax.set_xlim(0, 10.5)
    ax.set_yticks(range(n))
    ax.set_yticklabels([c for c, _ in COLD], fontsize=9.5, color=t["ink"])
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: "%g%%" % v))
    for i, r in enumerate(vals):
        cyc = float(r["cycles"])
        ipct, dpct = 100 * float(r["istall"]) / cyc, 100 * float(r["dstall"]) / cyc
        gap = 2 * (10.5 / ax.get_window_extent().width)     # 2px surface gap between segments
        hbar(ax, i, 0, ipct - gap / 2, 18, t["s"][0], t, round_end=False)
        hbar(ax, i, ipct + gap / 2, ipct + dpct, 18, t["s"][1], t)
        ax.text(ipct + dpct + 0.12, i, "%.1f%%" % (ipct + dpct), va="center", ha="left", fontsize=9, color=t["ink2"])
    ax.set_xlabel("Memory stall, % of all cycles (19 benchmarks, code fetched from SRAM)", fontsize=9, color=t["ink2"])
    titles(fig, t, "With a program loader, instruction misses cost as much as data misses",
           "8 KB direct-mapped instruction cache, 16 KB data cache with the same line size")
    legend(fig, t, [(t["s"][0], "instruction-cache stall"), (t["s"][1], "data-cache stall")], marker=None)
    save(fig, "fig5_cold_start", mode)


if __name__ == "__main__":
    plt.rcParams.update({"font.family": ["Segoe UI", "DejaVu Sans"], "svg.fonttype": "none",
                         "axes.unicode_minus": False})
    for mode, t in THEMES.items():
        for f in (fig_speed, fig_assoc, fig_path, fig_programs, fig_cold):
            f(t, mode)
    print("figures in", OUT)
