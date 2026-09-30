# Loads: load-use stall, forwarding of load data from WB, and store/branch
# consumers of a load.
#
# EXPECT x3 = 154
# EXPECT x5 = 154
# EXPECT x7 = 154
# EXPECT x10 = 8
# EXPECT x11 = 8
# EXPECT x13 = 0
# EXPECT x14 = 9
# EXPECT x16 = 154
# EXPECT x18 = 0x55
# EXPECT x19 = 0xaa
# EXPECT m0 = 77
# EXPECT m1 = 77
# EXPECT m2 = 8
# EXPECT m3 = 0x55
    .globl _start
_start:
    addi x1, x0, 77
    sw   x1, 0(x0)          # mem[0] = 77
    lw   x2, 0(x0)
    add  x3, x2, x2         # load-use, distance 1: stall.  x3 = 154
    lw   x4, 0(x0)
    nop
    add  x5, x4, x4         # distance 2: load data forwarded from WB
    lw   x6, 0(x0)
    nop
    nop
    add  x7, x6, x6         # distance 3: regfile write-through

    # load -> store data (rs2)
    lw   x8, 0(x0)
    sw   x8, 4(x0)          # mem[1] = 77

    # load -> base register of the next load (rs1)
    addi x9, x0, 8
    sw   x9, 8(x0)          # mem[2] = 8
    lw   x10, 8(x0)         # x10 = 8
    lw   x11, 0(x10)        # address comes from the load above: mem[2] = 8

    # load -> branch operand
    lw   x12, 0(x0)         # 77
    beq  x12, x1, taken1    # taken
    addi x13, x0, 1         # wrong path
taken1:
    addi x14, x0, 9

    # two loads to the same register, consumer after the second
    lw   x15, 0(x0)
    lw   x15, 4(x0)
    add  x16, x15, x15

    # store then load of the same address
    addi x17, x0, 0x55
    sw   x17, 12(x0)
    lw   x18, 12(x0)
    add  x19, x18, x17
halt:
    j halt
