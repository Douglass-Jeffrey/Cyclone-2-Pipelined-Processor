# Load-use at distance 1: the one case the hazard unit MUST stall for.
# The add needs x2 in EX while the load is still in MEM, before its data
# exists, so exactly one bubble is inserted.
#
# EXPECT stalls = 1
# EXPECT x3 = 42
    .globl _start
_start:
    addi x1, x0, 21
    sw   x1, 0(x0)          # mem[0] = 21
    lw   x2, 0(x0)
    add  x3, x2, x2         # uses the load immediately -> 1 stall
halt:
    j    halt
