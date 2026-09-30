# A store reads two registers at two different stages:
#   rs1 (base address) is consumed in EX  -> a load producing it MUST stall
#   rs2 (store data)   is consumed in MEM -> a load producing it can be bypassed
# Exempting the whole store from the load-use interlock breaks the first case,
# and the damage is a store to the wrong address, not just a wrong value.
#
# EXPECT x3 = 40
# EXPECT x4 = 40
# EXPECT x5 = 40
# EXPECT x7 = 0x5a
# EXPECT x8 = 0x5a
# EXPECT x9 = 0x5a
# EXPECT x11 = 84
# EXPECT m0 = 40
# EXPECT m10 = 0x77
# EXPECT m11 = 0x77
# EXPECT m12 = 0x77
# EXPECT m16 = 0x5a
# EXPECT m17 = 0x5a
# EXPECT m18 = 0x5a
# EXPECT m19 = 0x5a
# EXPECT m20 = 0
# EXPECT m21 = 84
# EXPECT m22 = 84
    .globl _start
_start:
    addi x1, x0, 40
    sw   x1, 0(x0)          # mem[0] = 40, a valid byte address
    addi x2, x0, 0x77

    # ---- a load produces the store's BASE ADDRESS, at distance 1 / 2 / 3 ----
    # distance 1 needs the interlock: the address is computed in EX, one stage
    # before the MEM bypass could repair it.  Getting it wrong scribbles on
    # whatever address the stale operand happens to name (here mem[0]).
    lw   x3, 0(x0)
    sw   x2, 0(x3)          # mem[10] = 0x77
    lw   x4, 0(x0)
    nop
    sw   x2, 4(x4)          # mem[11] = 0x77
    lw   x5, 0(x0)
    nop
    nop
    sw   x2, 8(x5)          # mem[12] = 0x77

    # ---- a load produces the store's DATA, at distance 1 / 2 / 3 ----
    addi x6, x0, 0x5a
    sw   x6, 64(x0)         # mem[16] = 0x5a
    lw   x7, 64(x0)
    sw   x7, 68(x0)         # mem[17]: data bypassed in MEM, no stall needed
    lw   x8, 64(x0)
    nop
    sw   x8, 72(x0)         # mem[18]
    lw   x9, 64(x0)
    nop
    nop
    sw   x9, 76(x0)         # mem[19]

    # ---- rd == x0 on the load, rs2 == x0 on the store ----
    # x0 is hardwired zero, so this store must write 0.  A bypass that matches
    # on register number alone sees 0 == 0 and forwards the discarded load.
    lw   x0, 64(x0)         # legal: the load happens, the result is dropped
    sw   x0, 80(x0)         # mem[20] = 0, NOT 0x5a

    # ---- one load feeding BOTH the base and the data of the same store ----
    addi x10, x0, 84
    sw   x10, 88(x0)        # mem[22] = 84
    lw   x11, 88(x0)
    sw   x11, 0(x11)        # mem[21] = 84
halt:
    j halt
