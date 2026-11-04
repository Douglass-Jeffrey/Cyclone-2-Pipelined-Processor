"""Controller variants side by side: python table.py"""
import json, os, sys
SIM = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "sim")
tags = sys.argv[1:] or ["base", "wait1", "rd1", "rd1w1", "rd1wf", "rd2wf"]
names = {"base": "original (WAIT=2)", "wait1": "WAIT_CYCLES=1", "rd1": "1-cyc reads", "rd1w1": "1-cyc reads + WAIT=1",
         "rd1wf": "1-cyc reads + 2-cyc writes", "rd2wf": "2-cyc reads + 2-cyc writes"}
for mode in ("warm", "cold"):
    R = {t: json.load(open(os.path.join(SIM, "%s_%s.json" % (t, mode)))) for t in tags}
    suite = [p for p in R["base"] if not p.startswith("m_")]
    print("== %s" % mode)
    print("%-30s %10s %7s %9s %8s | %8s %8s %8s %8s" % ("controller", "suite cyc", "vs base", "mem stall", "per miss", "m_stream", "m_copy", "m_chase", "m_all"))
    for t in tags:
        r = R[t]; c = sum(r[p]["cycles"] for p in suite); b = sum(R["base"][p]["cycles"] for p in suite)
        st = sum(r[p]["dbusy"] + r[p]["icyc"] for p in suite)
        dm = sum(r[p]["dmiss"] for p in suite); db = sum(r[p]["dbusy"] for p in suite)
        mk = [("%+7.1f%%" % (100.0 * (r[k]["cycles"] - R["base"][k]["cycles"]) / R["base"][k]["cycles"])) if k in r else "-" for k in ("m_stream", "m_copy", "m_chase", "m_all")]
        print("%-30s %10d %+6.1f%% %9d %8.1f | %8s %8s %8s %8s" % (names.get(t, t), c, 100.0 * (c - b) / b, st, db / dm, *mk))
    for t in tags:
        r = R[t]["m_copy"]
        print("   %-28s m_copy: %d misses (%d dirty), %.1f cycles per miss" % (names.get(t, t), r["dmiss"], r["dwb"], r["dbusy"] / r["dmiss"]))
