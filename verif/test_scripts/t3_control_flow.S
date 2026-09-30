# Branches and jumps with no prediction: wrong-path instructions must be
# squashed and must not change any state (registers or memory).
#
# EXPECT x3 = 0
# EXPECT x4 = 0
# EXPECT x5 = 1
# EXPECT x6 = 2
# EXPECT x8 = 0
# EXPECT x9 = 15
# EXPECT x13 = 0
# EXPECT x14 = 5
# EXPECT x15 = 0
# EXPECT x16 = 6
# EXPECT x17 = 0x74
# EXPECT x18 = 0
# EXPECT x19 = 0x8c
# EXPECT x20 = 0x84
# EXPECT x21 = 0
# EXPECT x22 = 0
# EXPECT x23 = 7
# EXPECT m0 = 0
# EXPECT m1 = 0
    .globl _start
_start:
    addi x1, x0, 3
    addi x2, x0, 3
    beq  x1, x2, L1         # taken; operands forwarded from MEM and WB
    addi x3, x0, 111        # wrong path (in ID when the branch resolves)
    addi x4, x0, 222        # wrong path (being fetched)
L1: addi x5, x0, 1
    bne  x1, x2, L2         # not taken
    addi x6, x0, 2          # executes
L2:
    # a store on the wrong path must not reach memory
    addi x7, x0, 0x7f
    beq  x0, x0, L3
    sw   x7, 0(x0)
    sw   x7, 4(x0)
L3: lw   x8, 0(x0)          # still 0

    # counted loop, sum = 5+4+3+2+1; bne reads the addi right before it
    addi x9, x0, 0
    addi x10, x0, 5
loop:
    add  x9, x9, x10
    addi x10, x10, -1
    bne  x10, x0, loop

    # signed / unsigned compares
    addi x11, x0, -1
    addi x12, x0, 1
    blt  x11, x12, S1       # -1 < 1: taken
    addi x13, x0, 1
S1: bltu x11, x12, S2       # 0xffffffff < 1: not taken
    addi x14, x0, 5
S2: bge  x12, x11, S3       # 1 >= -1: taken
    addi x15, x0, 1
S3: bgeu x12, x11, S4       # 1 >= 0xffffffff: not taken
    addi x16, x0, 6
S4:
    jal  x17, T1            # link = address of the next instruction
    addi x18, x0, 1         # skipped
T1: auipc x19, 0            # x19 = address of this instruction
    addi x19, x19, 20       # -> address of T2
    jalr x20, 0(x19)        # rs1 forwarded from the addi; x20 = link
    addi x21, x0, 1         # skipped
    addi x22, x0, 1         # skipped
T2: addi x23, x0, 7
halt:
    j halt
