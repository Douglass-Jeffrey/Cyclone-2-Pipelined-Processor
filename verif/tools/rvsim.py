"""
RV32I reference model and assembler helper for the pipeline test
Models the pipelined processor cycle by cycle (no forwarding, BP knowledge)
"""
import os
import struct
import subprocess

M32 = 0xFFFFFFFF
DMEM_WORDS = 256
IMEM_WORDS = 512

GCC = "riscv-none-elf-gcc"
OBJCOPY = "riscv-none-elf-objcopy"


def assemble(src_path, hex_path):
    """
    Assemble src_path (RV32I, no compression) to a hex-word file at address 0.

    The intermediate .elf and .bin are written beside hex_path with the same
    stem (prog.hex -> prog.elf, prog.bin), so a test's folder reads cleanly.
    """
    stem = os.path.splitext(hex_path)[0]
    elf = stem + ".elf"
    binf = stem + ".bin"
    subprocess.check_call([GCC, "-march=rv32i", "-mabi=ilp32", "-nostdlib",
                           "-nostartfiles", "-Wl,-Ttext=0", "-Wl,--no-relax",
                           "-o", elf, src_path])
    subprocess.check_call([OBJCOPY, "-O", "binary", elf, binf])
    data = open(binf, "rb").read()
    words = [struct.unpack("<I", data[i:i + 4])[0] for i in range(0, len(data), 4)]
    with open(hex_path, "w") as f:
        for w in words:
            f.write("%08x\n" % w)
    return words


def sign_ext(v, bits):
    x = (1 << bits) - 1
    v = v & x
    return v - (1 << bits) if v >> (bits - 1) else v


class Ref:
    def __init__(self, words):
        self.imem = list(words) + [0] * (IMEM_WORDS - len(words))
        self.x = [0] * 32
        self.dmem = [0] * DMEM_WORDS
        self.pc = 0
        self.trace = []          # wb values (pc, instr, wen, rd, data)
        self.halted = False

    # little endian dmem, addresses wrap like rtl idxs
    def _word(self, addr):
        return (addr >> 2) % DMEM_WORDS

    def load(self, addr, f3):
        w = self.dmem[self._word(addr)]
        off = addr & 3
        if f3 == 0:   return sign_ext((w >> (8 * off)) & 0xFF, 8) & M32                 # LB
        if f3 == 1:   return sign_ext((w >> (16 * (off >> 1))) & 0xFFFF, 16) & M32      # LH
        if f3 == 4:   return (w >> (8 * off)) & 0xFF                                    # LBU
        if f3 == 5:   return (w >> (16 * (off >> 1))) & 0xFFFF                          # LHU
        return w                                                                        # LW

    def store(self, addr, f3, val):
        i = self._word(addr)
        off = addr & 3
        w = self.dmem[i]
        if f3 == 0:
            sh = 8 * off
            w = (w & ~(0xFF << sh)) | ((val & 0xFF) << sh)
        elif f3 == 1:
            sh = 8 * off              # RTL: 4'b0011 << boff  (aligned halfwords only)
            w = (w & ~(0xFFFF << sh)) | ((val & 0xFFFF) << sh)
        elif f3 == 2:
            w = val & M32
        self.dmem[i] = w & M32

    # Run a single instruction from imem
    def step(self):
        pc = self.pc
        instr = self.imem[(pc >> 2) % IMEM_WORDS]
        op = instr & 0x7F
        rd = (instr >> 7) & 31
        f3 = (instr >> 12) & 7
        rs1 = (instr >> 15) & 31
        rs2 = (instr >> 20) & 31
        f7b5 = (instr >> 30) & 1
        a = self.x[rs1]
        b = self.x[rs2]
        imm_i = sign_ext(instr >> 20, 12)
        imm_s = sign_ext(((instr >> 25) << 5) | ((instr >> 7) & 31), 12)
        imm_b = sign_ext(((instr >> 31) << 12) | (((instr >> 7) & 1) << 11) |
                     (((instr >> 25) & 0x3F) << 5) | (((instr >> 8) & 0xF) << 1), 13)
        imm_u = instr & 0xFFFFF000
        imm_j = sign_ext(((instr >> 31) << 20) | (((instr >> 12) & 0xFF) << 12) |
                     (((instr >> 20) & 1) << 11) | (((instr >> 21) & 0x3FF) << 1), 21)

        nxt = (pc + 4) & M32
        wr = None                       # value written to rd, if any

        if op == 0x37:                                  # LUI
            wr = imm_u
        elif op == 0x17:                                # AUIPC
            wr = (pc + imm_u) & M32
        elif op == 0x6F:                                # JAL
            wr = (pc + 4) & M32
            nxt = (pc + imm_j) & M32
        elif op == 0x67:                                # JALR
            wr = (pc + 4) & M32
            nxt = ((a + imm_i) & M32) & ~1
        elif op == 0x63:                                # BRANCH
            sa, sb = sign_ext(a, 32), sign_ext(b, 32)
            taken = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb,
                     6: a < b, 7: a >= b}.get(f3, False)
            if taken:
                nxt = (pc + imm_b) & M32
        elif op == 0x03:                                # LOAD
            wr = self.load((a + imm_i) & M32, f3)
        elif op == 0x23:                                # STORE
            self.store((a + imm_s) & M32, f3, b)
        elif op in (0x13, 0x33):                        # OP-IMM / OP
            y = imm_i & M32 if op == 0x13 else b
            sh = y & 31
            if f3 == 0:
                wr = (a - y) & M32 if (op == 0x33 and f7b5) else (a + y) & M32
            elif f3 == 1: wr = (a << sh) & M32
            elif f3 == 2: wr = 1 if sign_ext(a, 32) < sign_ext(y, 32) else 0
            elif f3 == 3: wr = 1 if a < y else 0
            elif f3 == 4: wr = a ^ y
            elif f3 == 5: wr = (sign_ext(a, 32) >> sh) & M32 if f7b5 else a >> sh
            elif f3 == 6: wr = a | y
            elif f3 == 7: wr = a & y
        # anything else is NOP

        wen = 1 if (wr is not None and rd != 0) else 0
        if wen:
            self.x[rd] = wr & M32
        self.trace.append((pc, instr, wen, rd if wen else 0, (wr & M32) if wen else 0))
        if op == 0x6F and nxt == pc: # JAL sets own pc -> halt
            self.halted = True
        self.pc = nxt

    def run(self, max_steps=100000):
        for _ in range(max_steps):
            self.step()
            if self.halted:
                return
        raise RuntimeError("reference model did not halt")


def trace_lines(trace):
    return ["%08x %08x %d %02x %08x" % t for t in trace]
