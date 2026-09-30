#!/usr/bin/env python3
"""Run randomly generated programs.

    python verif/run_randomized_tests.py                  200 programs (seeds 0..199)
    python verif/run_randomized_tests.py --count 1000     more programs
    python verif/run_randomized_tests.py --seed 17        just program 17, with full output
    python verif/run_randomized_tests.py --name fix_fwd   choose the build folder's name

Programs come from verif/tools/randgen.py.  The same seed always produces the
same program, so a failure can be reproduced exactly with --seed.  Only
failures are printed, plus a progress line every 50 programs.

Output: build/<run>/rand_<seed>/  program.S .hex .elf .bin, trace.txt, dump.txt
<run> is random_YYYY-MM-DD_HH-MM-SS unless --name is given.
"""
import argparse
import os
import sys

# harness.py (paths and shared machinery) sits in tools/ beside this script
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/tools")
import harness
import rvsim
from randgen import gen_random


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run randomly generated programs.")
    ap.add_argument("--count", type=int, default=200, help="number of programs (seeds 0..count-1)")
    ap.add_argument("--seed", type=int, help="run just this one program, with full output")
    ap.add_argument("--name", help="build folder name (default: random_<date>_<time>)")
    ap.add_argument("--dev", default=harness.DEV_DIR, help="design folder to test")
    args = ap.parse_args(argv)

    seeds = [args.seed] if args.seed is not None else list(range(args.count))
    run_dir = harness.new_run_dir("random", args.name)
    vvp = harness.build_rtl(args.dev, run_dir)

    failures = 0
    for s in seeds:
        name = "rand_%d" % s
        folder = run_dir + "/" + name
        os.makedirs(folder)
        src = folder + "/program.S"
        open(src, "w").write(gen_random(s))
        words = rvsim.assemble(src, folder + "/program.hex")
        errors, n, stalls = harness.check_against_ref(vvp, words, folder)
        if errors or args.seed is not None:
            failures += harness.report("%s  [%s]" % (name, src), errors, n, stalls)
        elif s % 50 == 0:
            print("ok    random 0..%d so far" % s)
    print("random programs: %d run" % len(seeds))

    return harness.finish(failures, run_dir)


if __name__ == "__main__":
    sys.exit(main())
