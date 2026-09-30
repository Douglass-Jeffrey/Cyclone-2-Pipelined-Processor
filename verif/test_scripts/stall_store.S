# A store of the value just loaded.  A store only needs its DATA (rs2) in MEM,
# one stage later than an ALU operand, and by then the load is in WB: the
# store-data bypass in pipeline.v's MEM stage supplies it, so no stall.
# (A store's BASE address, rs1, is different -- see stall_dist1 and
# t5_store_hazards.)
#
# EXPECT stalls = 0
# EXPECT m1 = 21
    .globl _start
_start:
    addi x1, x0, 21
    sw   x1, 0(x0)          # mem[0] = 21
    lw   x2, 0(x0)
    sw   x2, 4(x0)          # mem[1] = 21, data bypassed in MEM -> 0 stalls
halt:
    j    halt
