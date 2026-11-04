"""The simulator at today's organization must reproduce the RTL's counts exactly.

    python experiments/memory/model/validate.py [results_dir]
results_dir (default data/) holds rtl_base_warm.json / rtl_base_cold.json from the RTL
counter twin: dmiss, dwb, ld_miss, st_miss, and the I-cache miss count of the cold run
(code fetched from SRAM)."""
import json, os, sys
import cachesim, traces

res = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
warm = json.load(open(os.path.join(res, "rtl_base_warm.json")))
cold = json.load(open(os.path.join(res, "rtl_base_cold.json")))
ok = True
print("%-15s %7s %7s %5s %5s %7s %7s %7s %7s" % ("program", "dmiss", "model", "dwb", "model", "ld/st", "model", "imiss", "model"))
for n in traces.PROGS:
    data, fetch, _ = traces.load(n)
    d = cachesim.dcache(data.tolist())
    i = cachesim.icache(fetch.tolist())
    rw, rc = warm[n], cold[n]
    has_icnt = "icyc" in rc               # the run whose imiss field is the miss count
    good = (d["miss"] == rw["dmiss"] and d["wb"] == rw["dwb"] and d["ld_miss"] == rw["ld_miss"]
            and d["st_miss"] == rw["st_miss"] and (not has_icnt or i == rc["imiss"]))
    ok &= good
    print("%-15s %7d %7d %5d %5d %3d/%-3d %3d/%-3d %7s %7d %s" % (
        n, rw["dmiss"], d["miss"], rw["dwb"], d["wb"], rw["ld_miss"], rw["st_miss"], d["ld_miss"], d["st_miss"],
        rc["imiss"] if has_icnt else "-", i, "" if good else "MISMATCH"))
print("ALL MATCH" if ok else "MISMATCHES")
