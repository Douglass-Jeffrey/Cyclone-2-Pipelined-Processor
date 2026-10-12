# A branch predicted taken must stay in ID through a load-use stall: the
# stall outranks the prediction in the next_pc mux.  The bne reads the word
# loaded right before it, so every iteration stalls once.
#
# Walks mem[0..4] = 7,7,7,7,0, so the bne goes T,T,T,T,N.  From weakly
# not-taken, only the first taken and the final not-taken mispredict.
#
# EXPECT stalls = 5
# EXPECT flushes = 2
# EXPECT x1 = 20
# EXPECT x3 = 28
# EXPECT x4 = 0
# EXPECT x5 = 5
    .globl _start
_start:
    addi x2, x0, 7
    sw   x2, 0(x0)
    sw   x2, 4(x0)
    sw   x2, 8(x0)
    sw   x2, 12(x0)         # mem[4] stays 0: the terminator
    addi x1, x0, 0
walk:
    addi x1, x1, 4
    add  x3, x3, x4         # sums the previous iteration's load
    addi x5, x5, 1          # iteration count
    lw   x4, -4(x1)
    bne  x4, x0, walk       # needs the load right away -> 1 stall
halt:
    j    halt
