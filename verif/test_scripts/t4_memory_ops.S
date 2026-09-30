# Byte / halfword / word accesses, sign and zero extension, and store data
# arriving by forwarding from MEM, WB, the regfile bypass, and a load.
#
# EXPECT x2 = 0xffffff80
# EXPECT x3 = 0x80
# EXPECT x4 = 0xffffff80
# EXPECT x5 = 0xff80
# EXPECT x6 = 0xffffff80
# EXPECT x7 = 0xffff8001
# EXPECT x8 = 0x8001
# EXPECT x10 = 0x44332211
# EXPECT x11 = 0x44
# EXPECT x13 = 0x8001ff80
# EXPECT x15 = 0x44332211
# EXPECT m0 = 0x8001ff80
# EXPECT m2 = 0x44332211
# EXPECT m3 = 0x44
# EXPECT m4 = 0x8001ff80
# EXPECT m5 = 0x44332211
    .globl _start
_start:
    li   x1, 0x8001ff80
    sw   x1, 0(x0)
    lb   x2, 0(x0)          # 0xffffff80
    lbu  x3, 0(x0)          # 0x80
    lh   x4, 0(x0)          # 0xffffff80
    lhu  x5, 0(x0)          # 0xff80
    lb   x6, 3(x0)          # 0xffffff80
    lh   x7, 2(x0)          # 0xffff8001
    lhu  x8, 2(x0)          # 0x8001

    # byte stores; store data forwarded from 1, 2 and 3 instructions back
    addi x9, x0, 0x11
    sb   x9, 8(x0)
    addi x9, x0, 0x22
    nop
    sb   x9, 9(x0)
    addi x9, x0, 0x33
    nop
    nop
    sb   x9, 10(x0)
    addi x9, x0, 0x44
    sb   x9, 11(x0)
    lw   x10, 8(x0)         # 0x44332211
    sh   x9, 12(x0)
    lhu  x11, 12(x0)        # 0x44

    # store data from a load two instructions back (data live in WB)
    lw   x12, 0(x0)
    nop
    sw   x12, 16(x0)
    lw   x13, 16(x0)

    # load immediately followed by a store of its data (stall)
    lw   x14, 8(x0)
    sw   x14, 20(x0)
    lw   x15, 20(x0)
halt:
    j halt
