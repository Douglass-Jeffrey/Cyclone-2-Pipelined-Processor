#!/usr/bin/env python3
"""Run the benchmarks on the DE1 with chosen predictor configs; compare every readout word with Icarus.

    python experiments/bp_comparison/board_check.py --snapshot DIR --work SHORT_DIR CONFIG ... [--programs a,b] [--full]

Per config (FAMILY:IDX:HIST:LHIST): copies of DIR/dev and DIR/quartus under SHORT_DIR with the
predictor's defines (Quartus 13 hangs in deep paths), and one full compile, which must meet timing.
Per program: the I-cache's power-up contents are swapped into the compiled design (the .hdl.mif
Quartus made from program.hex, then quartus_cdb --update_mif and quartus_asm; --full recompiles
instead), the .sof is programmed over JTAG, the power-on reset runs the program to its halt, and
the 16 readout words are compared with tb_bench.v, the board's simulation twin, in Icarus.
Results: builds.csv, runs.csv and each raw JTAG readout in <config>/, under --out (default data/board/).
"""
import argparse
import csv
import glob
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rtl_check as R  # noqa: E402

QBIN = r"D:\altera\13.0sp1\quartus\bin64"
CABLE = "USB-Blaster [USB-0]"
BOARD = os.path.join(HERE, "data", "board")
# readout words by selector, as in quartus/bench.py and soc_top.v
WORDS = ["cycles", "retired", "stalls", "flushes", "x28", "x29", "x30", "x31", "status", "retiring_pc",
         "retiring_instr", "pc_in_id", "wb_data", "dcache_misses", "dcache_writebacks", "icache_misses"]


def q(tool, args, cwd, log):
    t0 = time.time()
    r = subprocess.run([os.path.join(QBIN, tool + ".exe")] + args, cwd=cwd, capture_output=True, text=True)
    with open(log, "a") as f:
        f.write("==== %s %s (exit %d, %.0f s)\n%s%s\n" % (tool, " ".join(args), r.returncode, time.time() - t0,
                                                         r.stdout, r.stderr))
    return r.returncode, r.stdout


def timing(qdir):
    """Every TimeQuest slack ([(type, ns)]) and the fit's logic elements and registers."""
    sta = open(os.path.join(qdir, "output_files", "soc_top.sta.summary")).read()
    slacks = [(t.strip(), float(s)) for t, s in re.findall(r"Type\s*:\s*(.+)\nSlack\s*:\s*(-?[\d.]+)", sta)]
    fit = open(os.path.join(qdir, "output_files", "soc_top.fit.summary")).read()
    les = int(re.search(r"Total logic elements : ([\d,]+)", fit).group(1).replace(",", ""))
    regs = int(re.search(r"Total registers : ([\d,]+)", fit).group(1).replace(",", ""))
    return slacks, les, regs


def icache_mif(qdir):
    """The .hdl.mif Quartus made from program.hex for the I-cache's data RAM."""
    found = [p for p in glob.glob(os.path.join(qdir, "db", "*.hdl.mif"))
             if '"program.hex"' in open(p).read(2000) and "WIDTH=32;" in open(p).read(2000)]
    assert len(found) == 1, found
    return found[0]


def write_mif(path, words):
    head = open(path).read().split("CONTENT BEGIN")[0]
    assert "DEPTH=2048;" in head and len(words) <= 2048
    words = words + [0] * (2048 - len(words))
    with open(path, "w") as f:
        f.write(head + "CONTENT BEGIN\n")
        f.writelines("\t%d :\t%s;\n" % (a, format(words[a], "032b")) for a in range(2047, -1, -1))
        f.write("END;\n")


def read_board(qdir):
    """The 16 words over JTAG once the program has halted, and the raw readout."""
    for _ in range(20):
        r = subprocess.run([os.path.join(QBIN, "quartus_stp.exe"), "-t", "read_results.tcl"], cwd=qdir,
                           capture_output=True, text=True)
        w = {int(n): int(h, 16) for n, h in
             re.findall(r"^\s*word\s+(\d+)\s.*0x([0-9A-Fa-f]{8})\s*$", r.stdout, re.M)}
        if len(w) == 16 and w[8] & 1:
            return w, r.stdout
        time.sleep(1)
    raise RuntimeError("board did not report a halted run:\n" + (r.stdout + r.stderr)[-1500:])


def sim_words(vvp, words, folder):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "program.hex"), "w") as f:
        f.writelines("%08x\n" % w for w in words)
    out = subprocess.run(["vvp", vvp, "+max=20000000", "+clken=full", "+speed=3"], cwd=folder,
                         capture_output=True, text=True).stdout
    w = {int(n): int(x) for n, x in re.findall(r"^word(\d+)=(\d+)$", out, re.M)}
    assert len(w) == 16 and "HALTED" in out, out[-500:]
    return w


def append(path, header, row):
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(header)
        w.writerow(row)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True, help="a clean copy holding dev/, quartus/ and verif/")
    ap.add_argument("--work", required=True, help="a short build folder")
    ap.add_argument("cfgs", nargs="+", help="FAMILY:IDX:HIST:LHIST")
    ap.add_argument("--programs", help="comma-separated (default: all 19)")
    ap.add_argument("--full", action="store_true", help="full compile per program instead of a RAM swap")
    ap.add_argument("--out", default=BOARD, help="where builds.csv, runs.csv and the readouts go")
    a = ap.parse_args()
    out_dir = a.out
    sys.path.insert(0, os.path.join(R.ROOT, "benchmarks"))
    sys.path.insert(0, os.path.join(a.snapshot, "verif", "tools"))
    import build as bench
    from rtl_sources import rtl_sources
    progs = a.programs.split(",") if a.programs else list(bench.BENCHES)
    tb = os.path.join(a.snapshot, "verif", "tb")
    for c in a.cfgs:
        fam, i, h, l = c.split(":")[0], *(int(x) for x in c.split(":")[1:])
        name = "%s_%d_%d_%d" % (fam, i, h, l)
        base = os.path.join(a.work, name + ("_full" if a.full else ""))
        shutil.rmtree(base, ignore_errors=True)
        dev, qdir = os.path.join(base, "dev"), os.path.join(base, "quartus")
        meta_w = R.make_dev(os.path.join(a.snapshot, "dev"), dev, fam, i, h, l)
        shutil.copytree(os.path.join(a.snapshot, "quartus"), qdir, ignore=shutil.ignore_patterns("db", "output_files",
                                                                                                 "incremental_db"))
        log = os.path.join(base, "quartus.log")
        out = os.path.join(out_dir, name)
        os.makedirs(out, exist_ok=True)
        vvp = os.path.join(base, "tb_bench.vvp")
        d = dev.replace("\\", "/")
        r = subprocess.run(["iverilog", "-g2005", "-I", d, "-o", vvp, tb + "/tb_bench.v", tb + "/sram_model.v"]
                           + rtl_sources(d), capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr
        for k, p in enumerate(progs):
            words = [int(w, 16) for w in open(os.path.join(bench.OUT, p + ".hex")).read().split()]
            t0 = time.time()
            if k == 0 or a.full:
                with open(os.path.join(qdir, "program.hex"), "w") as f:
                    f.writelines("%08x\n" % w for w in words)
                rc, _ = q("quartus_sh", ["--flow", "compile", "soc_top"], qdir, log)
                method = "full_compile"
                assert rc == 0, "compile failed, see " + log
                if k == 0:
                    slacks, les, regs = timing(qdir)
                    ok = all(s >= 0 for _, s in slacks)
                    setup = [s for t, s in slacks if t.startswith("Slow Model Setup")][0]
                    append(os.path.join(out_dir, "builds.csv"),
                           ["family", "idx_bits", "hist_bits", "lhist_bits", "meta_w", "logic_elements", "registers",
                            "setup_slack_ns", "all_slack_met", "compile_s", "method"],
                           [fam, i, h, l, meta_w, les, regs, setup, ok, "%.0f" % (time.time() - t0),
                            "full" if a.full else "swap"])
                    print("built %-24s %d LEs, setup slack %.3f ns, %s (%.0f s)"
                          % (c, les, setup, "timing met" if ok else "TIMING FAILED", time.time() - t0), flush=True)
                    if not ok:
                        break
            else:
                with open(os.path.join(qdir, "program.hex"), "w") as f:
                    f.writelines("%08x\n" % w for w in words)
                write_mif(icache_mif(qdir), words)
                rc1, _ = q("quartus_cdb", ["soc_top", "-c", "soc_top", "--update_mif"], qdir, log)
                rc2, _ = q("quartus_asm", ["soc_top", "-c", "soc_top"], qdir, log)
                assert rc1 == 0 and rc2 == 0, "update_mif/asm failed, see " + log
                method = "ram_swap"
            build_s = time.time() - t0
            sof = os.path.join(qdir, "output_files", "soc_top.sof")
            md5 = hashlib.md5(open(sof, "rb").read()).hexdigest()
            rc, _ = q("quartus_pgm", ["-c", CABLE, "-m", "jtag", "-o", "p;output_files/soc_top.sof"], qdir, log)
            assert rc == 0, "programming failed, see " + log
            board, raw = read_board(qdir)
            with open(os.path.join(out, p + ("_full" if a.full else "") + ".txt"), "w") as f:
                f.write(raw)
            sim = sim_words(vvp, words, os.path.join(base, "sim", p))
            diff = [WORDS[n] for n in range(16) if board[n] != sim[n]]
            append(os.path.join(out_dir, "runs.csv"),
                   ["family", "idx_bits", "hist_bits", "lhist_bits", "program", "method", "sof_md5", "build_s"]
                   + ["board_" + w for w in WORDS] + ["sim_" + w for w in WORDS] + ["differ", "match"],
                   [fam, i, h, l, p, method, md5, "%.0f" % build_s] + [board[n] for n in range(16)]
                   + [sim[n] for n in range(16)] + [" ".join(diff), not diff])
            print("%-5s %-24s %-15s %-12s flushes %7d / sim %7d  cycles %8d  %s"
                  % ("ok" if not diff else "DIFF", c, p, method, board[3], sim[3], board[0],
                     "" if not diff else "differ: " + " ".join(diff)), flush=True)


if __name__ == "__main__":
    main()
