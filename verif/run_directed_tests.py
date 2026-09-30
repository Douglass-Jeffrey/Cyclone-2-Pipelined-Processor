#!/usr/bin/env python3
"""Run the directed tests: hand-written programs in verif/test_scripts/.

    python verif/run_directed_tests.py                        every test in test_lists/default.txt
    python verif/run_directed_tests.py --list verif/test_lists/stall_only.txt
    python verif/run_directed_tests.py --test t2_load_use.S   just one test
    python verif/run_directed_tests.py --name fix_fwd         choose the build folder's name

A test list has one file name per line, exactly as it appears in
verif/test_scripts/ (e.g. t2_load_use.S), so names can be pasted straight in;
'#' starts a comment.  A test may carry annotations, checked against BOTH the
reference model and the RTL so the model is not taken on trust:

    # EXPECT x5 = 13        final value of a register
    # EXPECT m2 = 0x55      final value of a data-memory word
    # EXPECT stalls = 1     exact number of load-use stall cycles (RTL only)

Output: build/<run>/<test>/  program.hex .elf .bin, trace.txt, dump.txt
<test> is the file name without its extension (t2_load_use.S -> t2_load_use/).
<run> is directed_YYYY-MM-DD_HH-MM-SS unless --name is given.
"""
import argparse
import os
import re
import sys

# harness.py (paths and shared machinery) sits in tools/ beside this script
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/tools")
import harness
import rvsim
from listfile import read_list


# Why a test file name is not usable, or None if it is fine.  The name must
# match exactly: Windows would happily open t2.s for t2.S, but GCC decides how
# to assemble a file from the extension AS TYPED, and .s and .S differ to GCC.
def script_problem(filename):
    if filename in os.listdir(harness.TEST_SCRIPTS):
        return None
    problem = "no file %s in %s" % (filename, harness.TEST_SCRIPTS)
    if not os.path.splitext(filename)[1]:
        problem += "  (entries need their extension, e.g. %s.S)" % filename
    return problem


# Test file names from a list file, each checked to exist in test_scripts/
def read_test_list(path):
    if not os.path.isfile(path):
        sys.exit("no such test list: %s" % path)
    files, problems = [], []
    for n, filename in read_list(path):
        problem = script_problem(filename)
        if problem:
            problems.append("line %d: %s" % (n, problem))
        elif os.path.splitext(filename)[0] in [os.path.splitext(f)[0] for f in files]:
            # build folders drop the extension, so t2.S and t2.s would collide
            problems.append("line %d: %s is listed twice (or clashes with a file of the "
                            "same name and another extension)" % (n, filename))
        else:
            files.append(filename)
    if problems:
        sys.exit("%s:\n  %s" % (path, "\n  ".join(problems)))
    if not files:
        sys.exit("%s lists no tests" % path)
    return files


# Read a .S file's annotations: ([(kind, index, value), ...], stalls or None)
def parse_expect(path):
    values, stalls = [], None
    for line in open(path):
        m = re.match(r"#\s*EXPECT\s+stalls\s*=\s*(\d+)", line)
        if m:
            stalls = int(m.group(1))
            continue
        m = re.match(r"#\s*EXPECT\s+([xm])(\d+)\s*=\s*(-?\w+)", line)
        if m:
            values.append((m.group(1), int(m.group(2)), int(m.group(3), 0) & 0xFFFFFFFF))
    return values, stalls


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run the directed tests.")
    ap.add_argument("--list", default=harness.TEST_LISTS + "/default.txt",
                    help="test list file (default: verif/test_lists/default.txt)")
    ap.add_argument("--test", help="run just this one test file, e.g. t2_load_use.S (overrides --list)")
    ap.add_argument("--name", help="build folder name (default: directed_<date>_<time>)")
    ap.add_argument("--dev", default=harness.DEV_DIR, help="design folder to test")
    args = ap.parse_args(argv)

    # decide what to run before creating anything, so a typo leaves no empty folder
    if args.test:
        problem = script_problem(args.test)
        if problem:
            sys.exit(problem)
        files = [args.test]
    else:
        files = read_test_list(args.list)

    run_dir = harness.new_run_dir("directed", args.name)
    vvp = harness.build_rtl(args.dev, run_dir)

    failures = 0
    for filename in files:
        name = os.path.splitext(filename)[0]          # t2_load_use.S -> t2_load_use
        src = harness.TEST_SCRIPTS + "/" + filename
        folder = run_dir + "/" + name
        os.makedirs(folder)
        words = rvsim.assemble(src, folder + "/program.hex")
        values, stalls = parse_expect(src)
        failures += harness.report(name, *harness.check_against_ref(vvp, words, folder, values, stalls))

    return harness.finish(failures, run_dir)


if __name__ == "__main__":
    sys.exit(main())
