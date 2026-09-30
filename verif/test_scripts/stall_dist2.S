# Load-use at distance 2: one instruction between the load and its user.
# By the time the add is in EX the load is in WB, and its data is forwarded
# from there -- no stall.
#
# EXPECT stalls = 0
# EXPECT x3 = 42
    .globl _start
_start:
    addi x1, x0, 21
    sw   x1, 0(x0)          # mem[0] = 21
    lw   x2, 0(x0)
    nop
    add  x3, x2, x2         # forwarded from WB -> 0 stalls
halt:
    j    halt
