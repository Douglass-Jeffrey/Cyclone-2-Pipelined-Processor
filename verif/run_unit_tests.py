#!/usr/bin/env python3
"""Run the unit testbenches: one module each, compiled against the whole design.

    python verif/run_unit_tests.py                  every testbench in UNIT_TBS
    python verif/run_unit_tests.py --name bp_fix    choose the build folder's name
    python verif/run_unit_tests.py --dev DIR        test another copy of the design

Each testbench is compiled with every file in dev/rtl_sources.txt and itself
as the only top level (iverilog -s), so it always tests the same module the
pipeline uses.  A testbench passes if it compiles, runs, prints "PASSED" and
prints no line starting with FAIL.

Output: build/<run>/<tb>/  <tb>.vvp and log.txt
<run> is unit_YYYY-MM-DD_HH-MM-SS unless --name is given.
"""
import argparse
import os
import re
import subprocess
import sys

# harness.py (paths and shared machinery) sits in tools/ beside this script
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/tools")
import harness

# testbenches for modules in dev/rtl_sources.txt, relative to verif/tb/;
# each file's module is named after the file
UNIT_TBS = [
    "tb_branch_predictor.v",
    "WIP/tb_imem.v",
    "WIP/tb_dmem.v",
]


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run the unit testbenches.")
    ap.add_argument("--name", help="build folder name (default: unit_<date>_<time>)")
    ap.add_argument("--dev", default=harness.DEV_DIR, help="design folder to test")
    args = ap.parse_args(argv)

    run_dir = harness.new_run_dir("unit", args.name)
    failures = 0
    for rel in UNIT_TBS:
        top = os.path.splitext(os.path.basename(rel))[0]
        folder = run_dir + "/" + top
        os.makedirs(folder)
        vvp = folder + "/" + top + ".vvp"

        r = harness.compile_tb(args.dev, vvp, harness.TB_DIR + "/" + rel, top)
        out = r.stdout + r.stderr
        if r.returncode == 0:
            r = subprocess.run(["vvp", vvp], cwd=folder, capture_output=True, text=True)
            out += r.stdout + r.stderr
        open(folder + "/log.txt", "w").write(out)

        fails = re.findall(r"^FAIL.*$", out, re.M)
        if r.returncode == 0 and "PASSED" in out and not fails:
            print("ok    %s" % top)
            continue
        failures += 1
        print("FAIL  %s   (log: %s/log.txt)" % (top, folder))
        for line in (fails or out.strip().splitlines()[-5:])[:8]:
            print("      " + line)

    return harness.finish(failures, run_dir)


if __name__ == "__main__":
    sys.exit(main())
