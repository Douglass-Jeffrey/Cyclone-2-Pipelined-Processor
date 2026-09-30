# No false stall on an instruction with no source registers.
#
# lui has no rs1 or rs2, but its instruction word still has bits where those
# fields would be.  0x210 is chosen so BOTH fields read as x2 -- the register
# the load just wrote.  A hazard unit that compared register numbers without
# checking uses_rs1 / uses_rs2 would stall here for nothing.
#
# EXPECT stalls = 0
# EXPECT x3 = 0x210000
    .globl _start
_start:
    lw   x2, 0(x0)
    lui  x3, 0x210          # rs1/rs2 fields look like x2 -> must NOT stall
halt:
    j    halt
