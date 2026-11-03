#!/usr/bin/env python3
"""Build C benchmarks (CoreMark, Dhrystone, Embench-IoT, riscv-tests) for the core.

    python build.py                   fetch sources (first run), build all, self-check on rvsim
    python build.py coremark slre     just these
    python build.py --list            what each one exercises
    python build.py --rtl             also run each on the RTL (tb_pipeline + SRAM model) and
                                      compare every retired instruction, register and memory
                                      word with rvsim

Each benchmark lands in out/<name>.hex, ready for the board:

    cd ../quartus
    python bench.py ../benchmarks/out/coremark.hex      predict, install as program.hex
    (recompile, program the board, SW9:8 = 11, press KEY0)
    python bench.py ../benchmarks/out/coremark.hex --no-install --board

Upstream sources are fetched at pinned commits into ext/, which is not part of
this repo (Embench is GPL-3.0, riscv-tests BSD-3-Clause, CoreMark Apache-2.0).
Only rt/ lives here: start-up code, linker script, a small libc and the ports.

What it takes to run on the core:
  - code <= 8 KB: the I-cache preload is the only way code gets in (no loader)
  - no initialized data: loads can't reach code memory and the data region
    resets to zero, so .data/.rodata are rebuilt at start-up by generated li/sw
    stores (__data_init, linked last in .text so the second link moves nothing)
  - no CSRs, ecall or printf; main's return lands in x31, 0 = self-check passed
  - one iteration each (Embench LOCAL_SCALE_FACTOR 1, CoreMark ITERATIONS 1)
"""
import argparse
import glob
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RT = os.path.join(HERE, "rt")
EXT = os.path.join(HERE, "ext")
OUT = os.path.join(HERE, "out")
sys.path.insert(0, os.path.join(ROOT, "verif", "tools"))
import rvsim  # noqa: E402

UPSTREAM = {
    "embench-iot": ("https://github.com/embench/embench-iot.git", "09c2ed8c3b7008c95d08b038de4a3f6dc103ed70"),
    "riscv-tests": ("https://github.com/riscv-software-src/riscv-tests.git", "3df703cd52d5f0d8224e3c50bf03c6cb70efff98"),
    "coremark": ("https://github.com/eembc/coremark.git", "1f483d5b8316753a742cbf5590caf5bd0a4e4777"),
}
EMB = os.path.join(EXT, "embench-iot")
RVT = os.path.join(EXT, "riscv-tests", "benchmarks")
CM = os.path.join(EXT, "coremark")

CC, OBJCOPY, NM = "riscv-none-elf-gcc", "riscv-none-elf-objcopy", "riscv-none-elf-nm"
# -fno-optimize-crc: GCC 15 turns CoreMark's bitwise CRC loop into a 512 B table,
# which costs ~1.4 KB of __data_init and removes a branch the benchmark is meant to have.
# Calls link relaxed (jal, free in ID); unrelaxed they'd be auipc+jalr, a redirect each.
CFLAGS = ["-march=rv32i", "-mabi=ilp32", "-std=gnu17", "-ffreestanding", "-mstrict-align",
          "-msmall-data-limit=0", "-fno-asynchronous-unwind-tables", "-fno-unwind-tables",
          "-fno-optimize-crc", "-ffunction-sections", "-fdata-sections", "-w"]
MAX_STEPS = 6_000_000

# name: (suite, what it exercises); the first eight make a good general-purpose set
BENCHES = {
    "coremark":       ("CoreMark", "lists, matrix, state machine, CRC: the standard small-core benchmark"),
    "dhrystone":      ("riscv-tests", "calls and string copies, return-heavy"),
    "huffbench":      ("Embench", "Huffman coding: data-dependent branches, no software multiply"),
    "sglib-combined": ("Embench", "lists, trees, hash tables: the most branch sites"),
    "slre":           ("Embench", "regex matching: sensitive to predictor table size"),
    "median":         ("riscv-tests", "median-of-3 filter: correlated compares"),
    "matmult-int":    ("Embench", "matrix multiply: mostly software multiply"),
    "crc32":          ("Embench", "table CRC: a perfectly predictable loop"),
    "aha-mont64":     ("Embench", "64-bit Montgomery multiply"),
    "depthconv":      ("Embench", "depthwise convolution: multiply-heavy"),
    "edn":            ("Embench", "DSP kernels: almost all software multiply"),
    "md5sum":         ("Embench", "MD5: straight-line arithmetic"),
    "nettle-sha256":  ("Embench", "SHA-256: straight-line arithmetic"),
    "statemate":      ("Embench", "generated state-machine code (short)"),
    "tarfind":        ("Embench", "string search: divide-heavy"),
    "ud":             ("Embench", "LU decomposition (short)"),
    "towers":         ("riscv-tests", "Towers of Hanoi: recursion, linked lists (short)"),
    "multiply":       ("riscv-tests", "software multiply loop"),
    "vvadd":          ("riscv-tests", "vector add: one trivial loop"),
}


def config(name):
    """Sources, include dirs, defines and flags for one benchmark."""
    suite = BENCHES[name][0]
    if name == "coremark":
        return dict(srcs=[os.path.join(CM, f) for f in ("core_list_join.c", "core_main.c", "core_matrix.c",
                                                        "core_state.c", "core_util.c")]
                    + [os.path.join(RT, "coremark", "core_portme.c")],
                    incs=[os.path.join(RT, "coremark"), CM], defs=["ITERATIONS=1"],
                    opt="-Os",                     # -O2 is over 8 KB
                    src_defs={"core_main.c": ["main=coremark_main"]})
    if name == "dhrystone":
        d = os.path.join(RVT, "dhrystone")
        return dict(srcs=[os.path.join(d, "dhrystone.c"), os.path.join(d, "dhrystone_main.c"),
                          os.path.join(RT, "dhrystone", "dhry_check.c")],
                    incs=[os.path.join(RT, "dhrystone"), d], defs=[],
                    cflags=["-std=gnu89"],         # K&R-era code
                    src_defs={"dhrystone_main.c": ["main=dhry_main"]})
    if suite == "Embench":
        return dict(srcs=sorted(glob.glob(os.path.join(EMB, "src", name, "*.c")))
                    + [os.path.join(EMB, "support", "beebsc.c"), os.path.join(RT, "embench_main.c")],
                    incs=[os.path.join(EMB, "support"), os.path.join(EMB, "src", name)],
                    defs=["GLOBAL_SCALE_FACTOR=1", "WARMUP_HEAT=0"], one_iteration=True)
    return dict(srcs=sorted(glob.glob(os.path.join(RVT, name, "*.c"))),
                incs=[RT, os.path.join(RVT, name)], defs=[])


def run(cmd, cwd=None):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if r.returncode:
        msg = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l.lower()]
        raise RuntimeError("\n".join(msg[:4]) or (r.stderr + r.stdout)[-800:])
    return r.stdout


def fetch():
    """Shallow-fetch each upstream repo at its pinned commit (once)."""
    for name, (url, sha) in UPSTREAM.items():
        d = os.path.join(EXT, name)
        if os.path.isdir(os.path.join(d, ".git")) and run(["git", "rev-parse", "HEAD"], d).strip() == sha:
            continue
        print("fetching %s @ %s" % (name, sha[:10]))
        os.makedirs(d, exist_ok=True)
        run(["git", "init", "-q"], d)
        run(["git", "fetch", "-q", "--depth", "1", url, sha], d)
        run(["git", "checkout", "-q", "FETCH_HEAD"], d)


def compile_all(cfg, bdir):
    objs = []
    opt = cfg.get("opt", "-O2")
    for src in cfg["srcs"]:
        if cfg.get("one_iteration") and os.path.join(EMB, "src") in src:
            text = open(src, encoding="utf-8", errors="replace").read()
            text = re.sub(r"#define\s+LOCAL_SCALE_FACTOR\s+\d+", "#define LOCAL_SCALE_FACTOR 1", text)
            src = os.path.join(bdir, os.path.basename(src))
            open(src, "w", encoding="utf-8").write(text)
        extra = [opt] + cfg.get("cflags", []) + \
                ["-D" + d for d in cfg["defs"] + cfg.get("src_defs", {}).get(os.path.basename(src), [])]
        obj = os.path.join(bdir, os.path.basename(src) + ".o")
        run([CC] + CFLAGS + extra + sum([["-I", i] for i in cfg["incs"]], []) + ["-c", src, "-o", obj])
        objs.append(obj)
    for src in ("crt0.S", "libc_min.c"):
        obj = os.path.join(bdir, src + ".o")
        run([CC] + CFLAGS + [opt, "-fno-builtin", "-fno-tree-loop-distribute-patterns",
                             "-c", os.path.join(RT, src), "-o", obj])
        objs.append(obj)
    return objs


def datainit_src(base, data):
    """li/sw stores that rebuild the .data image; zero words are skipped (the region resets to 0)."""
    lines = ['    .section .datainit, "ax"', "    .globl __data_init", "__data_init:"]
    cur = last = None
    for off in range(0, len(data), 4):
        w = struct.unpack("<I", data[off:off + 4].ljust(4, b"\0"))[0]
        if w == 0:
            continue
        addr = base + off
        if cur is None or addr - cur > 2044:
            cur = addr
            lines.append("    li   t1, 0x%x" % cur)
        if w != last:
            lines.append("    li   t0, 0x%x" % w)
            last = w
        lines.append("    sw   t0, %d(t1)" % (addr - cur))
    lines.append("    ret")
    return "\n".join(lines) + "\n"


def link(objs, init_src, bdir, tag):
    s = os.path.join(bdir, "datainit_%s.S" % tag)
    open(s, "w").write(init_src)
    run([CC] + CFLAGS + ["-c", s, "-o", s + ".o"])
    elf = os.path.join(bdir, "%s.elf" % tag)
    run([CC] + CFLAGS + ["-nostdlib", "-nostartfiles", "-T", os.path.join(RT, "bench.ld"),
                         "-Wl,--gc-sections"] + objs + [s + ".o", "-lgcc", "-o", elf])
    syms = {}
    for line in run([NM, elf]).splitlines():
        p = line.split()
        if len(p) == 3:
            syms[p[2]] = int(p[0], 16)
    for sec in ("data", "text"):
        run([OBJCOPY, "-O", "binary", "-j", "." + sec, elf, os.path.join(bdir, "%s_%s.bin" % (tag, sec))])
    read = lambda sec: open(os.path.join(bdir, "%s_%s.bin" % (tag, sec)), "rb").read()  # noqa: E731
    return syms, read("data"), read("text")


def build(name):
    """Two-pass link -> out/<name>.hex; returns (words, code bytes, init bytes, data bytes)."""
    bdir = os.path.join(OUT, name)
    os.makedirs(bdir, exist_ok=True)
    objs = compile_all(config(name), bdir)
    stub = '    .section .datainit, "ax"\n    .globl __data_init\n__data_init:\n    ret\n'
    syms, data, text1 = link(objs, stub, bdir, "pass1")
    _, data2, text = link(objs, datainit_src(syms["__data_start"], data), bdir, "pass2")
    if data2 != data:
        raise RuntimeError("the data image moved between the two links")
    words = [struct.unpack("<I", text[i:i + 4])[0] for i in range(0, len(text), 4)]
    with open(os.path.join(OUT, name + ".hex"), "w") as f:
        f.writelines("%08x\n" % w for w in words)
    return words, len(text1), len(text) - len(text1), len(data)


def rtl_check(names):
    """Every built benchmark on tb_pipeline, compared with rvsim instruction by instruction."""
    import harness as H
    run_dir = H.new_run_dir("benchmarks")
    vvp = run_dir + "/tb_pipeline.vvp"
    r = H.compile_tb(H.DEV_DIR, vvp, H.TB_PIPELINE, extra=[H.SRAM_MODEL])
    if r.returncode:
        sys.exit(r.stdout + r.stderr)
    fails = 0
    for name in names:
        words = [int(w, 16) for w in open(os.path.join(OUT, name + ".hex")).read().split()]
        folder = run_dir + "/" + name
        os.makedirs(folder)
        with open(folder + "/program.hex", "w") as f:
            f.writelines("%08x\n" % w for w in words)
        errors, n, stalls, flushes = H.check_against_ref(vvp, words, folder, max_steps=MAX_STEPS)
        fails += H.report(name, errors, n, stalls, flushes)
    return H.finish(fails, run_dir)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("names", nargs="*", help="benchmarks to build (default: all)")
    ap.add_argument("--list", action="store_true", help="list the benchmarks and stop")
    ap.add_argument("--rtl", action="store_true", help="also compare each with rvsim on the RTL")
    args = ap.parse_args()

    if args.list:
        for n, (suite, what) in BENCHES.items():
            print("%-15s %-12s %s" % (n, suite, what))
        return 0
    bad = [n for n in args.names if n not in BENCHES]
    if bad:
        sys.exit("unknown benchmark(s): %s (see --list)" % ", ".join(bad))
    names = args.names or list(BENCHES)

    fetch()
    print("%-15s %6s %6s %6s  %-8s %9s" % ("benchmark", "code", "+init", "data", "rvsim", "instrs"))
    fails = 0
    for name in names:
        try:
            words, code, init, data = build(name)
        except RuntimeError as e:
            print("%-15s build failed: %s" % (name, e))
            fails += 1
            continue
        ref = rvsim.Ref(words)
        ref.run(MAX_STEPS)
        ok = ref.x[31] == 0
        fails += not ok
        print("%-15s %6d %6d %6d  %-8s %9d" % (name, code, init, data, "PASS" if ok else "FAIL(%d)" % ref.x[31],
                                             len(ref.trace)), flush=True)
    print("\n%s -> %s" % ("all built and passed" if not fails else "%d FAILED" % fails, OUT))
    if args.rtl and not fails:
        print()
        return rtl_check(names)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
