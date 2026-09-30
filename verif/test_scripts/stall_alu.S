# An ALU result used by the very next instruction.  The result exists at the
# end of EX, so it is forwarded from MEM -- ALU producers never stall.
#
# EXPECT stalls = 0
# EXPECT x3 = 2
    .globl _start
_start:
    addi x2, x0, 1
    add  x3, x2, x2         # forwarded from MEM -> 0 stalls
halt:
    j    halt
