"""The repo's test runners, with the testbenches clocked at the board's 20 ns.

    python run20.py [--tb DIR] unit|directed|random <that runner's arguments>

tb_pipeline, tb_bench and tb_dcache clock at 10 ns in the repo, so the SRAM model's
access-time check never sees a controller that samples one cycle after the address."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)).replace("\\", "/")
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path[:0] = [os.path.join(ROOT, "verif", "tools"), os.path.join(ROOT, "verif")]
import harness
args = sys.argv[1:]
tb = HERE + "/tb20"
if args[0] == "--tb":       # tb20_wbbuf: the drain-aware testbenches, for patches/c123 and combined
    tb, args = HERE + "/" + args[1], args[2:]
harness.TB_DIR = tb
harness.TB_PIPELINE = harness.TB_DIR + "/tb_pipeline.v"
which, argv = args[0], args[1:]
mod = {"unit": "run_unit_tests", "directed": "run_directed_tests", "random": "run_randomized_tests"}[which]
m = __import__(mod)
sys.argv = [mod + ".py"] + argv
sys.exit(m.main(argv))
