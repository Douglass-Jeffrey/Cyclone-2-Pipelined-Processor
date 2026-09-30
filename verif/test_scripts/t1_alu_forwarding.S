# ALU -> ALU dependencies at every distance, and the x0 special case.
#
#   distance 1  producer in MEM when consumer is in EX   -> forward from MEM
#   distance 2  producer in WB                           -> forward from WB
#   distance 3  producer writes regfile as consumer reads -> regfile write-through
#
# EXPECT x1 = 5
# EXPECT x2 = 8
# EXPECT x3 = 13
# EXPECT x4 = 26
# EXPECT x5 = 100
# EXPECT x6 = 200
# EXPECT x7 = 0
# EXPECT x8 = 5
# EXPECT x9 = 3
# EXPECT x10 = 6
# EXPECT x11 = 3
# EXPECT x12 = 2
# EXPECT x13 = 4
# EXPECT x14 = 1
# EXPECT x15 = 0
    .globl _start
_start:
    addi x1, x0, 5          # x1 = 5
    addi x2, x1, 3          # x2 = 8    x1 1 away
    add  x3, x2, x1         # x3 = 13   x2 1 away, x1 2 away
    add  x4, x3, x3         # x4 = 26   both operands from the same producer
    addi x5, x0, 100
    nop
    nop
    add  x6, x5, x5         # x6 = 200  x5 3 away: regfile write-through

    # x0 is hardwired zero: a write to it must never be forwarded
    addi x0, x0, 55
    add  x7, x0, x0         # x7 = 0
    add  x8, x0, x1         # x8 = 5

    # the youngest producer of a register wins
    addi x9, x0, 1
    addi x9, x9, 1
    addi x9, x9, 1          # x9 = 3
    add  x10, x9, x9        # x10 = 6
    sub  x11, x10, x9       # x11 = 3

    # MEM and WB both hold a write to x12: MEM (younger) must win
    addi x12, x0, 1
    addi x12, x0, 2
    add  x13, x12, x12      # x13 = 4 (not 2)

    # a write-less instruction with a matching rd field must not forward:
    # sw has no rd; its imm[4:0] bits sit where rd would be
    addi x14, x0, 1
    sw   x0, 4(x0)          # imm[4:0] = 4, no rd
    addi x15, x4, -26       # x4 - 26 = 0 ; must read real x4
halt:
    j halt
