# JAL is taken in ID (its target is in the instruction), so it never
# flushes.  JALR needs rs1, which is only reliable in EX, so each one
# redirects from EX: one flush apiece.  No conditional branches here.
#
# EXPECT flushes = 2
# EXPECT stalls = 1
# EXPECT x1 = 4
# EXPECT x2 = 0xc
# EXPECT x3 = 0x10
# EXPECT x4 = 0x18
# EXPECT x5 = 0
# EXPECT x6 = 0
# EXPECT x7 = 0
# EXPECT x8 = 0x38
# EXPECT x10 = 0x38
# EXPECT x11 = 0x30
# EXPECT x12 = 0
# EXPECT x13 = 0
# EXPECT x14 = 14
# EXPECT m0 = 0x38
    .globl _start
_start:
    jal  x1, J1             # 0x00: taken in ID, no flush
    addi x5, x0, 1          # 0x04: never fetched
J1: jal  x2, J2             # 0x08
    addi x6, x0, 1          # 0x0c: never fetched
J2: auipc x3, 0             # 0x10
    jalr x4, 12(x3)         # 0x14: rs1 forwarded from the auipc -> 0x1c, flush
    addi x7, x0, 1          # 0x18: wrong path, squashed
    la   x8, J3             # 0x1c: auipc + addi
    sw   x8, 0(x0)          # 0x24
    lw   x10, 0(x0)         # 0x28
    jalr x11, 0(x10)        # 0x2c: load-use stall, then -> J3, flush
    addi x12, x0, 1         # 0x30: wrong path, squashed
    addi x13, x0, 1         # 0x34: skipped
J3: addi x14, x0, 14        # 0x38
halt:
    j    halt
