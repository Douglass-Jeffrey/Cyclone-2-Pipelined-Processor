"""Shared machinery for the pipeline test runners.

run_directed_tests.py and run_randomized_tests.py both make a fresh build
folder, compile the testbench once, then run each program on the RTL and on
the reference model (rvsim.py) and compare.  That common part lives here.
"""
import datetime
import os
import re
import subprocess
import sys

import rvsim
from rtl_sources import rtl_sources

# ---- paths ---------------------------------------------------------------
# PROJECT is the only hard-coded location for the test runners.  If the
# project folder moves, edit this one line.
PROJECT = "C:/Users/dougl/OneDrive/Documents/dev_projects/Processor_design_proj/Pipelined_processor"

# the design (and dev/rtl_sources.txt)
DEV_DIR      = PROJECT + "/dev"

# directed tests (.S)
TEST_SCRIPTS = PROJECT + "/verif/test_scripts"

# lists of directed tests to run
TEST_LISTS   = PROJECT + "/verif/test_lists"

# the testbench
TB_PIPELINE  = PROJECT + "/verif/tb/tb_pipeline.v"

# one sub-folder per run
BUILD_ROOT   = PROJECT + "/build"


# Make a new build/<name>/ for this run; never reuse or overwrite an old one
def new_run_dir(kind, name=None):
    name = name or datetime.datetime.now().strftime(kind + "_%Y-%m-%d_%H-%M-%S")
    if os.path.basename(name) != name:
        sys.exit("--name must be a plain folder name, not a path: %r" % name)
    run_dir = BUILD_ROOT + "/" + name
    if os.path.exists(run_dir):
        sys.exit("build folder already exists, choose another --name: %s" % run_dir)
    os.makedirs(run_dir)
    print("build folder: %s\n" % run_dir)
    return run_dir


# Compile TB and DUT once, use same built pair for each test
def build_rtl(dev_dir, run_dir):
    vvp = run_dir + "/tb_pipeline.vvp"
    cmd = ["iverilog", "-g2005", "-I", dev_dir, "-o", vvp, TB_PIPELINE] + rtl_sources(dev_dir)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit("RTL failed to compile")
    return vvp


# Run compiled TB in test_folder
def run_rtl(vvp, test_folder, cycles):
    """Run the compiled testbench INSIDE test_folder.

    tb_pipeline.v reads program.hex and writes trace.txt / dump.txt there by
    fixed name, so no path is ever passed into the simulation.
    """
    r = subprocess.run(["vvp", vvp, "+cycles=%d" % cycles],
                       cwd=test_folder, capture_output=True, text=True)
    trace = test_folder + "/trace.txt"
    dump = test_folder + "/dump.txt"
    # $readmemh / $fopen report a missing file with an "ERROR:" line but let the
    # simulation carry on -- on a blank program.  Treat it as the failure it is.
    if r.returncode != 0 or "ERROR" in r.stdout + r.stderr or not os.path.exists(dump):
        raise RuntimeError("simulation failed:\n" + r.stdout + r.stderr)

    m = re.search(r"stalls=(\d+)", r.stdout)
    stalls = int(m.group(1)) if m else -1
    rtl_trace = [l.strip() for l in open(trace) if l.strip()]
    regs, mem = {}, {}
    for l in open(dump):
        k, v = l.split()
        (regs if k[0] == "x" else mem)[int(k[1:])] = int(v, 16)
    return rtl_trace, regs, mem, stalls


# ---- checking one program --------------------------------------------------
def check_against_ref(vvp, words, test_folder, expect=None, expect_stalls=None):
    """Run a program on the RTL and the model; return (errors, n_instr, stalls)."""
    ref = rvsim.Ref(words)
    ref.run()
    ref_trace = rvsim.trace_lines(ref.trace)
    cycles = 3 * len(ref_trace) + 60          # generous: CPI stays well under 3
    rtl_trace, regs, mem, stalls = run_rtl(vvp, test_folder, cycles)
    errors = []

    # 1. did it retire everything?
    if len(rtl_trace) < len(ref_trace):
        errors.append("RTL retired only %d of %d instructions (hang or lost instruction)"
                      % (len(rtl_trace), len(ref_trace)))

    # 2. instruction-by-instruction; only the FIRST mismatch is useful
    for i, (a, b) in enumerate(zip(ref_trace, rtl_trace)):
        if a != b:
            ctx = "\n".join("      ref[%d] %s" % (j, ref_trace[j]) for j in range(max(0, i - 3), i))
            errors.append("first trace mismatch at instruction #%d\n%s\n"
                          "    ref[%d] %s\n    rtl[%d] %s   (pc instr wen rd data)"
                          % (i, ctx, i, a, i, b))
            break

    # 3. anything retired after the end must be the `j .` halt loop repeating
    halt_pc = ref_trace[-1].split()[0]
    stray = [t for t in rtl_trace[len(ref_trace):] if t.split()[0] != halt_pc]
    if stray:
        errors.append("instructions retired after the halt loop: %s" % stray[:3])

    # 4. final state -- catches stores, which never appear in the trace
    for i in range(32):
        if regs.get(i) != ref.x[i]:
            errors.append("x%d: ref=%08x rtl=%08x" % (i, ref.x[i], regs.get(i, 0)))
    for i in range(rvsim.DMEM_WORDS):
        if mem.get(i) != ref.dmem[i]:
            errors.append("mem[%d]: ref=%08x rtl=%08x" % (i, ref.dmem[i], mem.get(i, 0)))

    # 5. hand-written values, checked against the model as well as the RTL
    for kind, idx, val in (expect or []):
        model = ref.x[idx] if kind == "x" else ref.dmem[idx]
        rtl = regs.get(idx) if kind == "x" else mem.get(idx)
        if model != val:
            errors.append("EXPECT %s%d=%08x but the reference model has %08x (model bug?)"
                          % (kind, idx, val, model))
        if rtl != val:
            errors.append("EXPECT %s%d=%08x but the RTL has %08x" % (kind, idx, val, rtl))

    # 6. exact stall count -- a pipeline that stalls needlessly still computes
    #    the right answers, so only this check can catch it
    if expect_stalls is not None and stalls != expect_stalls:
        errors.append("EXPECT stalls = %d but the RTL stalled %d cycle(s)"
                      % (expect_stalls, stalls))

    return errors, len(ref_trace), stalls


# Print one test's result; returns 1 if it failed, else 0
def report(name, errors, n, stalls):
    if not errors:
        print("ok    %-28s (%d instr, %d load-use stalls)" % (name, n, stalls))
        return 0
    print("FAIL  %-28s (%d instr)" % (name, n))
    for e in errors[:8]:
        print("      " + e)
    if len(errors) > 8:
        print("      ... %d more" % (len(errors) - 8))
    return 1


# Print the verdict; returns the process exit code
def finish(failures, run_dir):
    print("\n%s" % ("ALL PASSED" if failures == 0 else "%d FAILED" % failures))
    print("output in %s" % run_dir)
    return 1 if failures else 0
