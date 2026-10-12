# A mispredict in EX outranks a prediction in ID.  The beq is taken but its
# counter starts weakly not-taken, so the jal behind it is wrong-path while
# it sits in ID, where the predictor calls it taken.  The redirect must win:
# the jal never writes its link and its target never runs.
#
# EXPECT flushes = 1
# EXPECT x1 = 0
# EXPECT x2 = 0
# EXPECT x3 = 3
    .globl _start
_start:
    beq  x0, x0, T          # taken, predicted not taken
    jal  x1, W              # wrong path, predicted taken in ID
T:  addi x3, x0, 3
    j    halt
W:  addi x2, x0, 2          # reachable only through the wrong-path jal
halt:
    j    halt
