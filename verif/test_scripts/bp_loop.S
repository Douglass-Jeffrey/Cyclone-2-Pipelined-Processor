# Branch prediction on a counted loop.  The bne is the only conditional
# branch in the program, so no other branch can share its counter, whatever
# the table size or index function.
#
# The counter starts weakly not-taken: the first taken bne mispredicts, the
# middle three are predicted, and the final not-taken exit mispredicts.  The
# exit's wrong path is the loop top, which must be squashed.
#
# EXPECT flushes = 2
# EXPECT x1 = 15
# EXPECT x2 = 0
# EXPECT x3 = 99
    .globl _start
_start:
    addi x1, x0, 0
    addi x2, x0, 5
loop:
    add  x1, x1, x2         # 5+4+3+2+1
    addi x2, x2, -1
    bne  x2, x0, loop       # T,T,T,T,N
    addi x3, x0, 99
halt:
    j    halt
