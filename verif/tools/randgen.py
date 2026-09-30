"""Random RV32I program generator for the pipeline tests.

gen_random(seed) returns assembly source for one program.  The same seed always
produces the same program, so a failing random test can be regenerated exactly
(run_randomized_tests.py --seed N).

What the generator is biased towards, and why:
  * short dependency distances -- sources are drawn from the last 3
    destinations most of the time, so forwarding and the load-use interlock are
    exercised constantly instead of rarely;
  * x0 as a source and destination, which forwarding must never treat as real;
  * legal, aligned addresses inside the first 128 bytes of data memory (andi
    masks), so loads and stores collide with each other often;
  * forward-only branches and jumps, so every program is guaranteed to reach
    its final `j .` and halt.  Backward branches (loops) are therefore covered
    only by the directed tests.
"""
import random


R_OPS = ["add", "sub", "and", "or", "xor", "sll", "srl", "sra", "slt", "sltu"]
I_OPS = ["addi", "andi", "ori", "xori", "slti", "sltiu"]
SH_OPS = ["slli", "srli", "srai"]
BR_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = {"lw": (0x7C, 4), "lh": (0x7E, 2), "lhu": (0x7E, 2), "lb": (0x7F, 1), "lbu": (0x7F, 1)}
STORES = {"sw": (0x7C, 4), "sh": (0x7E, 2), "sb": (0x7F, 1)}


def gen_random(seed, ngroups=120):
    rnd = random.Random(seed)
    regs = list(range(1, 9))
    recent = []          # last few destinations: makes short RAW distances common

    def src():
        r = rnd.random()
        if r < 0.07:
            return 0
        if recent and r < 0.65:
            return rnd.choice(recent)
        return rnd.choice(regs)

    def dst():
        return 0 if rnd.random() < 0.06 else rnd.choice(regs)

    def wrote(d):
        if d:
            recent.append(d)
            del recent[:-3]

    def imm12():
        return rnd.choice([0, 1, -1, 2047, -2048, rnd.randint(-2048, 2047), rnd.randint(-64, 64)])

    groups = []          # each: dict(lines=[...], target=None|index)
    for i in range(ngroups):
        k = rnd.random()
        if k < 0.28:
            d = dst(); s1 = src(); s2 = src()
            g = ["%s x%d, x%d, x%d" % (rnd.choice(R_OPS), d, s1, s2)]; wrote(d)
            groups.append(dict(lines=g))
        elif k < 0.50:
            d = dst(); s1 = src()
            if rnd.random() < 0.3:
                g = ["%s x%d, x%d, %d" % (rnd.choice(SH_OPS), d, s1, rnd.randint(0, 31))]
            else:
                g = ["%s x%d, x%d, %d" % (rnd.choice(I_OPS), d, s1, imm12())]
            wrote(d)
            groups.append(dict(lines=g))
        elif k < 0.54:
            d = dst()
            g = ["%s x%d, %d" % (rnd.choice(["lui", "auipc"]), d, rnd.randint(0, 0xFFFFF))]; wrote(d)
            groups.append(dict(lines=g))
        elif k < 0.66:
            op = rnd.choice(list(LOADS)); mask, al = LOADS[op]
            d = dst()
            off = rnd.randrange(0, 124, al)
            g = ["andi x10, x%d, %d" % (src(), mask), "%s x%d, %d(x10)" % (op, d, off)]; wrote(d)
            groups.append(dict(lines=g))
        elif k < 0.76:
            op = rnd.choice(list(STORES)); mask, al = STORES[op]
            off = rnd.randrange(0, 124, al)
            g = ["andi x10, x%d, %d" % (src(), mask), "%s x%d, %d(x10)" % (op, src(), off)]
            groups.append(dict(lines=g))
        elif k < 0.78:
            d = dst(); off = rnd.randrange(0, 124, 4)
            g = ["andi x10, x%d, 124" % src(), "sw x%d, %d(x10)" % (src(), off),
                 "lw x%d, %d(x10)" % (d, off)]; wrote(d)
            groups.append(dict(lines=g))
        elif k < 0.83:
            # a load produces the BASE ADDRESS of a following store: rs1 is
            # consumed in EX, so this must interlock, unlike store data.
            # x11 holds an address that is itself stored in memory, so the
            # loaded value is a legal base.
            gap = ["nop"] * rnd.randint(0, 2)
            g = ["andi x10, x%d, 124" % src(), "andi x11, x%d, 124" % src(),
                 "sw x11, 0(x10)", "lw x11, 0(x10)"] + gap + \
                ["sw x%d, 0(x11)" % src()]
            groups.append(dict(lines=g))
        elif k < 0.85:
            # rd == x0 on a load, rs2 == x0 on the store behind it
            g = ["andi x10, x%d, 124" % src(), "lw x0, 0(x10)",
                 "sw x0, 0(x10)"]
            groups.append(dict(lines=g))
        elif k < 0.91:
            t = min(i + rnd.randint(1, 4), ngroups)
            g = ["%s x%d, x%d, {L}" % (rnd.choice(BR_OPS), src(), src())]
            groups.append(dict(lines=g, target=t))
        elif k < 0.95:
            d = dst(); t = min(i + rnd.randint(1, 3), ngroups)
            g = ["jal x%d, {L}" % d]; wrote(d)
            groups.append(dict(lines=g, target=t))
        else:
            d = dst(); s1 = src(); s2 = src()
            g = ["auipc x10, 0", "jalr x%d, 12(x10)" % d,
                 "add x%d, x%d, x%d" % (dst(), s1, s2)]   # skipped by the jalr
            wrote(d)
            groups.append(dict(lines=g))

    out = ["    .globl _start", "_start:"]
    for r in regs:
        out.append("    li x%d, %d" % (r, rnd.randint(-2**31, 2**31 - 1)))
    for i, g in enumerate(groups):
        out.append("L%d:" % i)
        for ln in g["lines"]:
            out.append("    " + ln.replace("{L}", "L%d" % g["target"] if g.get("target") is not None else ""))
    out.append("L%d:" % ngroups)
    out.append("    j L%d" % ngroups)
    return "\n".join(out) + "\n"
