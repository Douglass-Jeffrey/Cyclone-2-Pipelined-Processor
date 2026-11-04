"""Cycle model on top of the miss counts -> data/summary_*.csv, data/per_program.csv, data/m4k.csv

    python experiments/memory/model/analyze.py [results_dir]
results_dir (default data/) holds rtl_base_warm.json / rtl_base_cold.json, the RTL counter
twin's measurements of today's design (tb_mem.v: cycles, dbusy, dmiss, dwb, icyc, imiss).

Miss penalties follow dev/src/dcache.v / icache.v / sram_ctl.v cycle by cycle, for a line of L
bytes (B = L/2 beats on the 16-bit SRAM bus, L/4 words through a 32-bit M4K port):
  fill        = 6 + B*c_read + lat + L/4     6 = miss seen, dirty check, request, ack, ack seen, tag
  write-back  = (L/4 + 1) + 3 + B*c_write    victim read out of the M4K, request/ack, beats
  I-cache     = fill - 0.93                  the measured overlap with the back end draining
Today (L = 16, 4 cycles a beat) that gives 42 per clean miss and 82 per dirty miss, which is
exactly what the RTL counter twin measures (checked below).  An associative cache is charged
the same penalties (its extra way mux and LRU update are assumed to cost no cycles).
Write-validate: a word-store miss allocates in 3 cycles (+ the write-back of a dirty victim);
a load of a not-yet-valid word costs a fill.
"""
import csv
import json
import math
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
MICRO = ("m_stream", "m_copy", "m_chase")
SPEEDS = [  # name, cycles per read beat, extra read latency per line, cycles per write beat
    ("today", 4, 0, 4),
    ("wait1", 3, 0, 3),
    ("burst", 1, 1, 3),
]
I_OVERLAP = 0.93


def fill(L, sp, wide=False):
    _, cr, lat, _ = sp
    return 6 + (L // 2) * cr + lat + (1 if wide else L // 4)


def wb_extra(L, sp, wide=False):
    _, _, _, cw = sp
    return ((1 if wide else L // 4) + 1) + 3 + (L // 2) * cw


def d_stall(r, sp, wide=False):
    L = int(r["line"])
    f, w = fill(L, sp, wide), wb_extra(L, sp, wide)
    return (int(r["miss"]) * f + (int(r["dirty_miss"]) + int(r["alloc_dirty"])) * w
            + int(r["alloc"]) * 3 + int(r["partial"]) * f)


def i_stall(r, sp, wide=False):
    return int(r["miss"]) * (fill(int(r["line"]), sp, wide) - I_OVERLAP)


# ---- M4K feasibility (Cyclone II M4K: 4 Kbit, 4096x1 .. 128x36) ----
SHAPES = [(4096, 1), (2048, 2), (1024, 4), (512, 9), (256, 18), (128, 36)]


def blocks(depth, width):
    return min(math.ceil(depth / d) * math.ceil(width / w) for d, w in SHAPES)


def d_m4k(size, line, ways, wv):
    sets = size // (line * ways)
    tag = 18 - int(math.log2(sets)) - int(math.log2(line))
    data = ways * blocks(size // ways // 4, 32)                  # each way reads a 32-bit word at once
    tagram = blocks(sets, ways * (tag + 1))                      # every way's {valid, tag} at once
    dirty = blocks(sets, ways * (1 + (line // 4 if wv else 0)))  # dirty (+ per-word valid bits)
    return data, tagram, dirty


def i_m4k(size, line, ways):
    sets = size // (line * ways)
    tag = 18 - int(math.log2(sets)) - int(math.log2(line))
    return ways * blocks(size // ways // 4, 32), blocks(sets, ways * (tag + 1))


def rows(path):
    return list(csv.DictReader(open(path)))


def write(path, rs):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rs[0]))
        w.writeheader()
        w.writerows(rs)


def key(r):
    return (r["size"], r["line"], r["ways"], r["wv"])


def main(res):
    warm = json.load(open(os.path.join(res, "rtl_base_warm.json")))
    cold = json.load(open(os.path.join(res, "rtl_base_cold.json")))
    noncache = {n: v["cycles"] - v["dbusy"] for n, v in warm.items()}   # cycles with no miss stalls
    D = rows(os.path.join(DATA, "dcache_counts.csv"))
    I = rows(os.path.join(DATA, "icache_counts.csv"))
    d_today = {r["program"]: r for r in D if key(r) == ("16384", "16", "1", "0")}

    # the model at today's organization and speed must equal the measured stall cycles
    today = SPEEDS[0]
    for n, r in d_today.items():
        assert d_stall(r, today) == warm[n]["dbusy"], n
    cold_err = []
    for r in I:
        if (r["size"], r["line"], r["ways"]) == ("8192", "16", "1"):
            n = r["program"]
            model = noncache[n] + d_stall(d_today[n], today) + i_stall(r, today)
            cold_err.append(abs(model - cold[n]["cycles"]) / cold[n]["cycles"])
    print("model check: warm stall cycles exact on all %d programs; cold total cycles within %.2f%% (worst program)"
          % (len(warm), 100 * max(cold_err)))

    # data cache, warm (code preloaded, as on the board): suite totals and per program
    summ, per = [], []
    by = defaultdict(list)
    for r in D:
        by[key(r)].append(r)
    for wide in (False, True):
        for (size, line, ways, wv), rs in by.items():
            data, tagram, dirty = d_m4k(int(size), int(line), int(ways), int(wv))
            suite = [r for r in rs if r["program"] not in MICRO]
            for sp in SPEEDS:
                st = {r["program"]: d_stall(r, sp, wide) for r in rs}
                tot = sum(noncache[r["program"]] + st[r["program"]] for r in suite)
                s_st = sum(st[r["program"]] for r in suite)
                summ.append(dict(
                    size=size, line=line, ways=ways, wv=wv, port="line" if wide else "32", speed=sp[0],
                    miss=sum(int(r["miss"]) for r in suite), alloc=sum(int(r["alloc"]) for r in suite),
                    partial=sum(int(r["partial"]) for r in suite), wb=sum(int(r["wb"]) for r in suite),
                    stall=s_st, cycles=tot, stall_pct=round(100.0 * s_st / tot, 3),
                    mean_prog_stall_pct=round(sum(100.0 * st[r["program"]] / (noncache[r["program"]] + st[r["program"]])
                                                  for r in suite) / len(suite), 3),
                    m_stream=st["m_stream"], m_copy=st["m_copy"], m_chase=st["m_chase"],
                    m4k_data=data, m4k_tag=tagram, m4k_dirty=dirty, m4k_dcache=data + tagram + dirty))
                for r in rs:
                    n = r["program"]
                    per.append(dict(program=n, size=size, line=line, ways=ways, wv=wv,
                                    port="line" if wide else "32", speed=sp[0], miss=r["miss"], wb=r["wb"],
                                    alloc=r["alloc"], stall=st[n], cycles=noncache[n] + st[n],
                                    stall_pct=round(100.0 * st[n] / (noncache[n] + st[n]), 3)))
    write(os.path.join(DATA, "summary_dcache.csv"), summ)
    write(os.path.join(DATA, "per_program.csv"), per)

    # cold start (code fetched from SRAM): 16 KB direct-mapped dcache with the icache's line size
    cold_rows = []
    iorgs = sorted({(r["size"], r["line"], r["ways"]) for r in I}, key=lambda t: tuple(map(int, t)))
    for wide in (False, True):
        for isz, il, iw in iorgs:
            irs = [r for r in I if (r["size"], r["line"], r["ways"]) == (isz, il, iw) and r["program"] not in MICRO]
            drs = {r["program"]: r for r in D if key(r) == ("16384", il, "1", "0")}
            idata, itag = i_m4k(int(isz), int(il), int(iw))
            for sp in SPEEDS:
                ist = sum(i_stall(r, sp, wide) for r in irs)
                dst = sum(d_stall(drs[r["program"]], sp, wide) for r in irs)
                tot = sum(noncache[r["program"]] for r in irs) + ist + dst
                cold_rows.append(dict(isize=isz, iline=il, iways=iw, dline=il, port="line" if wide else "32",
                                      speed=sp[0], imiss=sum(int(r["miss"]) for r in irs), istall=round(ist),
                                      dstall=dst, cycles=round(tot), stall_pct=round(100.0 * (ist + dst) / tot, 3),
                                      m4k_icache=idata + itag))
    write(os.path.join(DATA, "summary_cold.csv"), cold_rows)

    # M4K budget per organization pair (dcache + icache <= 52)
    m4k = []
    for size in (8192, 16384, 32768):
        for line in (16, 32, 64):
            for ways in (1, 2, 4):
                for wv in (0, 1):
                    dd = d_m4k(size, line, ways, wv)
                    for isize in (8192, 16384):
                        ii = i_m4k(isize, line, 1)
                        m4k.append(dict(dsize=size, line=line, dways=ways, wv=wv, isize=isize, iways=1,
                                        m4k_ddata=dd[0], m4k_dtag=dd[1], m4k_ddirty=dd[2], m4k_dcache=sum(dd),
                                        m4k_icache=sum(ii), total=sum(dd) + sum(ii), fits=int(sum(dd) + sum(ii) <= 52),
                                        lru_regs=(size // (line * ways)) * (ways - 1),
                                        line_buf_bits=line * 8))
    write(os.path.join(DATA, "m4k.csv"), m4k)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DATA)
