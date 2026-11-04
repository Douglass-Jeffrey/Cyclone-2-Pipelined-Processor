#!/usr/bin/env python3
"""Synthesize the whole SoC with one predictor config at a time; record its cost.

    python experiments/bp_comparison/quartus_cost.py --snapshot DIR --work DIR FAMILY:IDX:HIST:LHIST ...

DIR holds dev/ and quartus/ from HEAD.  Each config is compiled in
<work>/<name>/ (one compile at a time), and data/quartus.csv gets its logic
elements, registers, slow-model setup slack at 50 MHz, Fmax and whether it fit.
"""
import argparse
import csv
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import predictors as P  # noqa: E402
from rtl_check import TYPES  # noqa: E402

QUARTUS = "D:/altera/13.0sp1/quartus/bin64"
WORST_TCL = """project_open soc_top
create_timing_netlist -model slow
read_sdc
update_timing_netlist
foreach_in_collection p [get_timing_paths -setup -npaths 1] {
  puts "slack [get_path_info $p -slack]"
  puts "from  [get_node_info -name [get_path_info $p -from]]"
  puts "to    [get_node_info -name [get_path_info $p -to]]"
}
project_close
"""
COLS = ["family", "idx_bits", "hist_bits", "lhist_bits", "state_bits", "meta_w", "fit", "logic_elements",
        "registers", "setup_slack_ns", "fmax_mhz", "meets_50mhz", "worst_path_to"]


def build_one(snapshot, work, fam, i, h, l):
    name = "%s_%d_%d_%d" % (fam, i, h, l)
    b = os.path.join(work, "%s%d_%d_%d" % (fam[0], i, h, l))    # short: Quartus 13 limits path length
    if os.path.isdir(b):
        shutil.rmtree(b)
    shutil.copytree(os.path.join(snapshot, "dev"), os.path.join(b, "dev"))
    os.makedirs(os.path.join(b, "quartus"))
    for f in ("soc_top.qpf", "soc_top.qsf", "soc_top.sdc", "soc_top.v", "program.hex"):
        shutil.copy(os.path.join(snapshot, "quartus", f), os.path.join(b, "quartus", f))
    meta_w = max(32, P.meta_bits(fam, i, h, l))
    p = os.path.join(b, "dev", "defines.vh")
    s = open(p).read()
    for k, v in (("BP_TYPE", "`" + TYPES[fam]), ("BP_IDX_BITS", i), ("BP_HIST_BITS", max(h, 2)),
                 ("BP_LHIST_BITS", max(l, 2)), ("BP_META_W", meta_w)):
        s, n = re.subn(r"(`define\s+%s\s+)\S+" % k, r"\g<1>%s" % v, s)
        assert n == 1, k
    open(p, "w").write(s)
    q = os.path.join(b, "quartus")
    with open(os.path.join(q, "compile.log"), "w") as log:
        rc = subprocess.run([QUARTUS + "/quartus_sh.exe", "--flow", "compile", "soc_top"], cwd=q,
                            stdout=log, stderr=subprocess.STDOUT).returncode
    row = [fam, i, h, l, P.build(fam, i, h, l).bits, meta_w, rc == 0, "", "", "", "", False, ""]
    fit = os.path.join(q, "output_files", "soc_top.fit.summary")
    if rc == 0 and os.path.exists(fit):
        t = open(fit).read()
        row[7] = int(re.search(r"Total logic elements : ([\d,]+)", t).group(1).replace(",", ""))
        row[8] = int(re.search(r"Total registers : (\d+)", t).group(1))
        sta = open(os.path.join(q, "output_files", "soc_top.sta.summary")).read()
        slack = float(re.search(r"Slow Model Setup 'CLOCK_50'\s*\nSlack : (-?[\d.]+)", sta).group(1))
        row[9], row[10], row[11] = slack, round(1000.0 / (20.0 - slack), 2), slack >= 0
        with open(os.path.join(q, "worst.tcl"), "w") as f:
            f.write(WORST_TCL)
        w = subprocess.run([QUARTUS + "/quartus_sta.exe", "-t", "worst.tcl"], cwd=q, capture_output=True,
                           text=True).stdout
        m = re.search(r"^to\s+(.*)$", w, re.M)
        row[12] = m.group(1).split("|")[-1] if m else ""
    else:
        err = [x for x in open(os.path.join(q, "compile.log")).read().splitlines() if x.startswith("Error")]
        row[12] = (err[0][:150] if err else "compile failed")
    print(name, row[6:], flush=True)
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("cfgs", nargs="+", help="FAMILY:IDX:HIST:LHIST")
    a = ap.parse_args()
    path = os.path.join(HERE, "data", "quartus.csv")
    for c in a.cfgs:
        fam, *n = c.split(":")
        row = build_one(a.snapshot, a.work, fam, *map(int, n))
        new = not os.path.exists(path)
        with open(path, "a", newline="") as f:
            w = csv.writer(f)
            if new:
                w.writerow(COLS)
            w.writerow(row)


if __name__ == "__main__":
    main()
