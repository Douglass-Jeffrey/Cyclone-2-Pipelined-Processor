#!/usr/bin/env python3
"""Print the numbers the README's findings quote (after sweep.py and breakdown.py).

    python experiments/bp_comparison/summary.py
"""
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from plots import FAMILIES, DEFAULTS, LABEL, cfg, cfg_text, frontier, load  # noqa: E402

BUDGETS = [64, 256, 1024, 2048, 4096, 8192, 32768]


def main():
    sweep = load("sweep.csv")
    per_prog = load("sweep_per_program.csv")
    by = defaultdict(list)
    for r in sweep:
        by[(r["family"], r["workload"])].append(r)

    for wl in ("softmul", "hwmul"):
        print("\n==== %s ====" % wl)
        for s in ("static_not_taken", "static_btfn"):
            r = by[(s, wl)][0]
            print("%-18s MPKI %6.2f  mean %6.2f  rate %.3f" % (s, r["mpki"], r["mean_program_mpki"], r["mispredict_rate"]))
        print("defaults:")
        for f in FAMILIES:
            r = [r for r in by[(f, wl)] if cfg(r) == DEFAULTS[f]][0]
            print("  %-10s %5d bits  MPKI %6.2f  mean %6.2f  rate %.4f  mispredicts %d" % (
                f, r["state_bits"], r["mpki"], r["mean_program_mpki"], r["mispredict_rate"], r["mispredicts"]))
        print("best buildable config at <= budget (MPKI | mean-program MPKI):")
        print("  %-10s" % "" + "".join("%18s" % b for b in BUDGETS))
        for f in FAMILIES:
            rows = [r for r in by[(f, wl)] if r["rtl_buildable"] == "True"]
            line = "  %-10s" % f
            for b in BUDGETS:
                c = [r for r in rows if r["state_bits"] <= b]
                if not c:
                    line += "%18s" % "-"
                    continue
                best = min(c, key=lambda r: r["mpki"])
                bm = min(c, key=lambda r: r["mean_program_mpki"])
                line += "%11.2f |%5.2f" % (best["mpki"], bm["mean_program_mpki"])
            print(line)
        print("frontier configs at budgets:")
        for f in FAMILIES:
            rows = [r for r in by[(f, wl)] if r["rtl_buildable"] == "True"]
            for b in (1024, 4096, 8192, 32768):
                c = [r for r in rows if r["state_bits"] <= b]
                best = min(c, key=lambda r: r["mpki"])
                print("  %-10s <=%5d: %-32s %5d bits  MPKI %6.2f  meta %d" % (
                    f, b, cfg_text(best), best["state_bits"], best["mpki"], best["meta_bits"]))
        # gshare / corr best history per table size; local best lhist per slot count
        for f in ("gshare", "corr", "gshare_low_variant", "corr_spec_variant", "gshare_late_variant"):
            best = {}
            for r in by[(f, wl)]:
                n = r["idx_bits"] + r["hist_bits"]
                if n not in best or r["mpki"] < best[n]["mpki"]:
                    best[n] = r
            print("  %-20s best hist per index bits: %s" % (f, " ".join(
                "%d:h%d=%.1f" % (n, best[n]["hist_bits"], best[n]["mpki"]) for n in sorted(best))))
        best = {}
        for r in by[("local", wl)]:
            i = r["idx_bits"]
            if i not in best or r["mpki"] < best[i]["mpki"]:
                best[i] = r
        print("  local best lhist per slot bits: %s" % " ".join(
            "%d:l%d=%.1f" % (i, best[i]["lhist_bits"], best[i]["mpki"]) for i in sorted(best)))
        best = {}
        for r in by[("local", wl)]:
            l = r["lhist_bits"]
            if l not in best or r["mpki"] < best[l]["mpki"]:
                best[l] = r
        print("  local best slots per lhist: %s" % " ".join(
            "%d:i%d=%.1f" % (l, best[l]["idx_bits"], best[l]["mpki"]) for l in sorted(best)))

    # cycles: instrs + load-use stalls + jalr flushes + mispredicts (warm icache, cache misses excluded)
    rtl = load("rtl_cycles_bimodal_default.csv")
    instrs = sum(r["instrs"] for r in rtl)
    stalls = sum(r["load_use_stalls"] for r in rtl)
    bim = [r for r in by[("bimodal", "softmul")] if cfg(r) == DEFAULTS["bimodal"]][0]
    jalr = sum(r["flushes"] for r in rtl) - bim["mispredicts"]
    base = instrs + stalls + jalr + bim["mispredicts"]
    print("\ncycles as built with the bimodal default: %d (instrs %d, stalls %d, jalr %d, mispredicts %d = %.1f%%)"
          % (base, instrs, stalls, jalr, bim["mispredicts"], 100.0 * bim["mispredicts"] / base))
    for b in (2048, 1 << 30):
        print("best config <= %s bits: cycles saved vs the bimodal default" % (b if b < 1 << 30 else "any"))
        for f in FAMILIES:
            c = [r for r in by[(f, "softmul")] if r["rtl_buildable"] == "True" and r["state_bits"] <= b]
            best = min(c, key=lambda r: r["mpki"])
            saved = bim["mispredicts"] - best["mispredicts"]
            print("  %-10s %-32s %6d bits  %7d cycles = %.2f%%" % (f, cfg_text(best), best["state_bits"], saved,
                                                                 100.0 * saved / base))

    # per-program winners at 1K and 8K, as built and without libgcc
    for wl in ("softmul", "hwmul"):
        for b in (1024, 8192):
            picks = {}
            for f in FAMILIES:
                c = [r for r in by[(f, wl)] if r["rtl_buildable"] == "True" and r["state_bits"] <= b]
                picks[f] = cfg(min(c, key=lambda r: r["mpki"]))
            wins = defaultdict(list)
            pp = defaultdict(dict)
            for r in per_prog:
                if r["workload"] == wl and r["family"] in picks and cfg(r) == picks[r["family"]]:
                    pp[r["program"]][r["family"]] = r["mpki"]
            for p, d in pp.items():
                order = sorted(d, key=d.get)
                a, b2 = d[order[0]], d[order[1]]
                wins[order[0] if b2 - a >= max(0.1, 0.02 * b2) else "tie"].append(p)
            print("\n%s <=%d bits, per-program winners: %s" % (wl, b, {k: len(v) for k, v in wins.items()}))
            for f, ps in wins.items():
                print("   %s: %s" % (f, ", ".join(sorted(ps))))


if __name__ == "__main__":
    main()
