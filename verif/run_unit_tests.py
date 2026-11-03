#!/usr/bin/env python3
"""Run the unit testbenches: one module each, compiled against the whole design.

    python verif/run_unit_tests.py                  every testbench in UNIT_TBS
    python verif/run_unit_tests.py --name bp_fix    choose the build folder's name
    python verif/run_unit_tests.py --dev DIR        test another copy of the design

Each testbench is compiled with every file in dev/rtl_sources.txt, plus the
extra files UNIT_TBS lists for it (retired modules, the SRAM model), and itself as
the only top level (iverilog -s), so it always tests the same module the
pipeline uses.  A testbench passes if it compiles, runs, prints "PASSED" and
prints no line starting with FAIL.

tb_branch_predictor and tb_bp_trace run once per predictor in
bp_model.RTL_MODELS (TYPE set with iverilog -P), not just the one dev/defines.vh
builds.  tb_bp_trace replays a trace.hex that bp_model.unit_trace writes for
that predictor at TRACE_SIZES, so the model and the RTL are sized alike.

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
import bp_model
import harness

# (testbench relative to verif/tb/, files it needs beyond dev/rtl_sources.txt,
# relative to the project); each testbench's module is named after its file
SRAM_FILES = ["verif/tb/sram_model.v"]
UNIT_TBS = [
    ("tb_branch_predictor.v", []),
    ("tb_bp_trace.v",         []),
    ("tb_imem.v",             ["dev/src/imem.v"]),     # imem/dmem: retired by the caches
    ("tb_dmem.v",             ["dev/src/dmem.v"]),
    ("tb_sram_ctl.v",         SRAM_FILES),
    ("tb_sram_memtest.v",     ["quartus/sram_test/sram_memtest.v"] + SRAM_FILES),
    ("tb_dcache.v",           SRAM_FILES),     # ~45 s: 50,000 random accesses
]
BP_TBS = ("tb_branch_predictor", "tb_bp_trace")
# tb_bp_trace's table sizes: small, so its few branches collide often
TRACE_SIZES = {"IDX_BITS": 4, "HIST_BITS": 3, "LHIST_BITS": 3}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run the unit testbenches.")
    ap.add_argument("--name", help="build folder name (default: unit_<date>_<time>)")
    ap.add_argument("--dev", default=harness.DEV_DIR, help="design folder to test")
    args = ap.parse_args(argv)

    run_dir = harness.new_run_dir("unit", args.name)
    bp = bp_model.rtl_config(args.dev + "/defines.vh")
    failures = 0
    for rel, extra in UNIT_TBS:
        top = os.path.splitext(os.path.basename(rel))[0]
        runs = [(top, None)]
        if top in BP_TBS:                   # BP_CORR -> tb_branch_predictor_corr, TYPE=1
            runs = [(top + "_" + t[3:].lower(), {"TYPE": bp[t]}) for t in bp_model.RTL_MODELS]
        for name, params in runs:
            folder = run_dir + "/" + name
            os.makedirs(folder)
            vvp = folder + "/" + top + ".vvp"
            if top == "tb_bp_trace":
                t = [k for k in bp_model.RTL_MODELS if bp[k] == params["TYPE"]][0]
                params.update(TRACE_SIZES)
                pred = bp_model.RTL_MODELS[t]({"BP_" + k: v for k, v in TRACE_SIZES.items()})
                with open(folder + "/trace.hex", "w") as f:
                    f.writelines("%08x\n" % w for w in bp_model.unit_trace(pred, seed=1))

            r = harness.compile_tb(args.dev, vvp, harness.TB_DIR + "/" + rel, top,
                                   [harness.PROJECT + "/" + f for f in extra], params)
            out = r.stdout + r.stderr
            if r.returncode == 0:
                r = subprocess.run(["vvp", vvp], cwd=folder, capture_output=True, text=True)
                out += r.stdout + r.stderr
            open(folder + "/log.txt", "w").write(out)

            fails = re.findall(r"^FAIL.*$", out, re.M)
            if r.returncode == 0 and "PASSED" in out and not fails:
                print("ok    %s" % name)
                continue
            failures += 1
            print("FAIL  %s   (log: %s/log.txt)" % (name, folder))
            for line in (fails or out.strip().splitlines()[-5:])[:8]:
                print("      " + line)

    return harness.finish(failures, run_dir)


if __name__ == "__main__":
    sys.exit(main())
