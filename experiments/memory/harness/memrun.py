"""Run tb_mem.v (the board's counter twin + memory accounting) on every program.

    python memrun.py <dev_dir> <tag> [warm,cold] [--only a,b]  -> ../data/sim/<tag>_<mode>.json

Programs: the 19 in benchmarks/out plus the memory kernels in ../model/programs.
Each result has the board's counters, freeze/miss cycles, and x28..x31; check()
compares a design's results with the baseline's (tag "base") so a faster design must compute
the same thing and retire the same instructions."""
import json, os, re, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
KERNELS = os.path.join(os.path.dirname(HERE), "model", "programs")
RESULTS = os.path.join(os.path.dirname(HERE), "data", "sim")
sys.path[:0] = [os.path.join(ROOT, "verif", "tools"), os.path.join(ROOT, "benchmarks")]
from rtl_sources import rtl_sources
import build as B

MICRO = ["m_stream", "m_copy", "m_chase", "m_all"]
def hexfile(n):
    return os.path.join(KERNELS, n + ".hex") if n in MICRO else os.path.join(B.OUT, n + ".hex")
PROGS = sorted(B.BENCHES) + MICRO

def run(dev, tag, modes=("warm", "cold"), only=None):
    progs = [p for p in PROGS if not only or p in only]
    out = os.path.join(ROOT, "build", "memrun", tag)
    shutil.rmtree(out, ignore_errors=True); os.makedirs(out)
    vvp = os.path.join(out, "tb_mem.vvp")
    r = subprocess.run(["iverilog", "-g2005", "-I", dev, "-o", vvp, os.path.join(HERE, "tb_mem.v"),
                        os.path.join(ROOT, "verif", "tb", "sram_model.v")] + rtl_sources(dev),
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr)
    def one(job):
        n, mode = job
        d = os.path.join(out, mode, n); os.makedirs(d)
        shutil.copy(hexfile(n), os.path.join(d, "program.hex"))
        p = subprocess.run(["vvp", vvp, "+max=40000000", "+icache=" + mode], cwd=d,
                           capture_output=True, text=True).stdout
        open(os.path.join(d, "log.txt"), "w").write(p)
        if "HALTED" not in p or "SRAM MODEL ERROR" in p or "ERROR" in p:
            return job, {"error": p[-600:]}
        w = {int(k): int(v) for k, v in re.findall(r"^word(\d+)=(\d+)$", p, re.M)}
        a = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", re.search(r"^acct (.*)$", p, re.M).group(1))}
        return job, {"cycles": w[0], "retired": w[1], "stalls": w[2], "flushes": w[3],
                     "x28": w[4], "x29": w[5], "x30": w[6], "x31": w[7],
                     "dmiss": w[13], "dwb": w[14], "imiss": w[15], **a}
    jobs = [(n, m) for m in modes for n in progs]
    with ThreadPoolExecutor(7) as ex:
        res = dict(ex.map(one, jobs))
    os.makedirs(RESULTS, exist_ok=True)
    for m in modes:
        data = {n: v for (n, mm), v in res.items() if mm == m}
        json.dump(data, open(os.path.join(RESULTS, "%s_%s.json" % (tag, m)), "w"), indent=1)
        bad = [n for n, v in data.items() if "error" in v]
        print("%s %s: %d programs, %d errors %s" % (tag, m, len(data), len(bad), bad), flush=True)
    return res

def load(tag, mode):
    return json.load(open(os.path.join(RESULTS, "%s_%s.json" % (tag, mode))))

def check(tag, mode, base="base"):
    """Programs whose results or retired count differ from the baseline's."""
    a, b = load(tag, mode), load(base, mode)
    return [n for n in a if "error" in a[n] or n not in b or
            any(a[n][k] != b[n][k] for k in ("retired", "x28", "x29", "x30", "x31"))]

if __name__ == "__main__":
    args = sys.argv[1:]
    only = None
    if "--only" in args:
        i = args.index("--only"); only = args[i + 1].split(","); del args[i:i + 2]
    dev, tag = args[0], args[1]
    modes = tuple(args[2].split(",")) if len(args) > 2 else ("warm", "cold")
    run(dev, tag, modes, only)
    if tag != "base" and os.path.exists(os.path.join(RESULTS, "base_%s.json" % modes[0])):
        for m in modes:
            print("%s %s: differs from base on %s" % (tag, m, check(tag, m) or "nothing"))
