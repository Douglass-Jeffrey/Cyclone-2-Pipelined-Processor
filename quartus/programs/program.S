.section .text
.global _start
#
# Self-checking RV32I coverage test
#
# gp (x3) holds the number of the test currently being checked, so on
# failure you know exactly which one broke. a0 (x10) is 1 on overall pass,
# 0 on overall fail; both loop forever afterward, so a testbench (or
# dbg_pc) only needs to see which address it's stuck at.
#
# Tests 1-4 bootstrap trust in addi/add/lui using only self-contained
# arithmetic (no `li` pseudo-op yet, since `li` itself may expand through
# lui/addi). Every test after that uses `li`/`la` freely.
#
_start:

    # ---- 1: addi ----
    addi gp, x0, 1
    addi t0, x0, 5
    addi t1, x0, 5
    bne  t0, t1, fail

    # ---- 2: addi, negative immediate (imm bit 30 set must not act like SUB) ----
    addi gp, x0, 2
    addi t0, x0, -1
    addi t1, x0, -1
    bne  t0, t1, fail

    # ---- 3: add ----
    addi gp, x0, 3
    addi t0, x0, 5
    addi t1, x0, 7
    add  t2, t0, t1
    addi t3, x0, 12
    bne  t2, t3, fail

    # ---- 4: lui bootstrap (build 4096 independently via three small addi's) ----
    addi gp, x0, 4
    lui  t0, 1
    addi t1, x0, 2047
    addi t1, t1, 2047
    addi t1, t1, 2
    bne  t0, t1, fail

    # ==== R-type ALU (li/lui/addi now trusted) ====

    # ---- 5: sub ----
    addi gp, x0, 5
    li   t0, 7
    li   t1, 5
    sub  t2, t0, t1
    li   t3, 2
    bne  t2, t3, fail

    # ---- 6: and ----
    addi gp, x0, 6
    li   t0, 0xF0F0
    li   t1, 0x0FF0
    and  t2, t0, t1
    li   t3, 0x00F0
    bne  t2, t3, fail

    # ---- 7: or ----
    addi gp, x0, 7
    li   t0, 0xF000
    li   t1, 0x0F00
    or   t2, t0, t1
    li   t3, 0xFF00
    bne  t2, t3, fail

    # ---- 8: xor ----
    addi gp, x0, 8
    li   t0, 0xFF
    li   t1, 0x0F
    xor  t2, t0, t1
    li   t3, 0xF0
    bne  t2, t3, fail

    # ---- 9: sll ----
    addi gp, x0, 9
    li   t0, 1
    li   t1, 4
    sll  t2, t0, t1
    li   t3, 16
    bne  t2, t3, fail

    # ---- 10: srl (logical: must NOT sign-extend) ----
    addi gp, x0, 10
    li   t0, -1
    li   t1, 4
    srl  t2, t0, t1
    li   t3, 0x0FFFFFFF
    bne  t2, t3, fail

    # ---- 11: sra (arithmetic: must sign-extend) ----
    addi gp, x0, 11
    li   t0, -16
    li   t1, 2
    sra  t2, t0, t1
    li   t3, -4
    bne  t2, t3, fail

    # ---- 12: slt (signed) ----
    addi gp, x0, 12
    li   t0, -1
    li   t1, 1
    slt  t2, t0, t1        # -1 <s 1  -> 1
    li   t3, 1
    bne  t2, t3, fail
    slt  t4, t1, t0        #  1 <s -1 -> 0
    bne  t4, x0, fail

    # ---- 13: sltu (unsigned; same operands as #12, opposite outcome) ----
    addi gp, x0, 13
    li   t0, -1             # 0xFFFFFFFF, huge unsigned
    li   t1, 1
    sltu t2, t0, t1         # huge <u 1 -> 0
    bne  t2, x0, fail
    sltu t4, t1, t0         # 1 <u huge -> 1
    li   t3, 1
    bne  t4, t3, fail

    # ==== OP-IMM ====

    # ---- 14: andi ----
    addi gp, x0, 14
    li   t0, 0xF0F0
    andi t2, t0, 0x0F0
    li   t3, 0x0F0
    bne  t2, t3, fail

    # ---- 15: ori ----
    addi gp, x0, 15
    li   t0, 0xF000
    ori  t2, t0, 0x0F0
    li   t3, 0xF0F0
    bne  t2, t3, fail

    # ---- 16: xori (incl. imm=-1 bitwise-not idiom) ----
    addi gp, x0, 16
    li   t0, 0xFF
    xori t2, t0, 0x0F
    li   t3, 0xF0
    bne  t2, t3, fail
    xori t4, t0, -1
    li   t5, -256
    bne  t4, t5, fail

    # ---- 17: slli ----
    addi gp, x0, 17
    li   t0, 1
    slli t2, t0, 5
    li   t3, 32
    bne  t2, t3, fail

    # ---- 18: srli ----
    addi gp, x0, 18
    li   t0, -1
    srli t2, t0, 4
    li   t3, 0x0FFFFFFF
    bne  t2, t3, fail

    # ---- 19: srai ----
    addi gp, x0, 19
    li   t0, -16
    srai t2, t0, 2
    li   t3, -4
    bne  t2, t3, fail

    # ---- 20: slti (signed) ----
    addi gp, x0, 20
    li   t0, -1
    slti t2, t0, 1          # -1 <s 1  -> 1
    li   t3, 1
    bne  t2, t3, fail
    slti t4, t0, -2         # -1 <s -2 -> 0
    bne  t4, x0, fail

    # ---- 21: sltiu (unsigned) ----
    addi gp, x0, 21
    li   t0, -1
    sltiu t2, t0, 1         # huge <u 1 -> 0
    bne  t2, x0, fail
    li   t0, 0
    sltiu t4, t0, 1         # 0 <u 1 -> 1
    li   t3, 1
    bne  t4, t3, fail

    # ==== Loads / stores (dmem is a separate word array; use literal addresses) ====

    # ---- 22: sw / lw round trip ----
    addi gp, x0, 22
    li   s2, 0x40
    li   t0, 0x11223344
    sw   t0, 0(s2)
    lw   t1, 0(s2)
    bne  t0, t1, fail

    # ---- 23: sb / lb (sign-extend) / lbu (zero-extend) ----
    addi gp, x0, 23
    li   t0, -128           # 0xFFFFFF80, low byte = 0x80
    sb   t0, 4(s2)
    lb   t1, 4(s2)
    bne  t0, t1, fail       # sign-extended back to -128
    lbu  t2, 4(s2)
    li   t3, 0x80
    bne  t2, t3, fail       # zero-extended to 128

    # ---- 24: sh / lh (sign-extend) / lhu (zero-extend) ----
    addi gp, x0, 24
    li   t0, -4660          # 0xFFFFEDCC, low halfword = 0xEDCC
    sh   t0, 8(s2)
    lh   t1, 8(s2)
    bne  t0, t1, fail
    lhu  t2, 8(s2)
    li   t3, 0xEDCC
    bne  t2, t3, fail

    # ---- 25: byte-lane independence (4x SB must not clobber neighbors) ----
    addi gp, x0, 25
    li   t0, 0x11
    sb   t0, 12(s2)
    li   t0, 0x22
    sb   t0, 13(s2)
    li   t0, 0x33
    sb   t0, 14(s2)
    li   t0, 0x44
    sb   t0, 15(s2)
    lw   t1, 12(s2)
    li   t2, 0x44332211
    bne  t1, t2, fail

    # ==== Branches: both taken and not-taken for each ====

    # ---- 26: beq ----
    addi gp, x0, 26
    li   s0, 111
    li   t0, 5
    li   t1, 6
    beq  t0, t1, 1f          # must NOT take
    li   s0, 222
1:  li   t2, 222
    bne  s0, t2, fail        # confirms fallthrough happened
    li   s0, 111
    li   t0, 7
    li   t1, 7
    beq  t0, t1, 2f          # must take
    li   s0, 999             # poison
2:  li   t2, 111
    bne  s0, t2, fail        # confirms poison skipped

    # ---- 27: bne ----
    addi gp, x0, 27
    li   s0, 111
    li   t0, 7
    li   t1, 7
    bne  t0, t1, 1f          # must NOT take
    li   s0, 222
1:  li   t2, 222
    bne  s0, t2, fail
    li   s0, 111
    li   t0, 5
    li   t1, 6
    bne  t0, t1, 2f          # must take
    li   s0, 999
2:  li   t2, 111
    bne  s0, t2, fail

    # ---- 28: blt (signed) ----
    addi gp, x0, 28
    li   s0, 111
    li   t0, 1
    li   t1, -1
    blt  t0, t1, 1f          # 1 <s -1 -> must NOT take
    li   s0, 222
1:  li   t2, 222
    bne  s0, t2, fail
    li   s0, 111
    li   t0, -1
    li   t1, 1
    blt  t0, t1, 2f          # -1 <s 1 -> must take
    li   s0, 999
2:  li   t2, 111
    bne  s0, t2, fail

    # ---- 29: bge (signed) ----
    addi gp, x0, 29
    li   s0, 111
    li   t0, -1
    li   t1, 1
    bge  t0, t1, 1f          # -1 >=s 1 -> must NOT take
    li   s0, 222
1:  li   t2, 222
    bne  s0, t2, fail
    li   s0, 111
    li   t0, 1
    li   t1, -1
    bge  t0, t1, 2f          # 1 >=s -1 -> must take
    li   s0, 999
2:  li   t2, 111
    bne  s0, t2, fail

    # ---- 30: bltu (unsigned; same operands as #28/29, opposite outcome) ----
    addi gp, x0, 30
    li   s0, 111
    li   t0, -1              # huge unsigned
    li   t1, 1
    bltu t0, t1, 1f          # huge <u 1 -> must NOT take
    li   s0, 222
1:  li   t2, 222
    bne  s0, t2, fail
    li   s0, 111
    li   t0, 1
    li   t1, -1
    bltu t0, t1, 2f          # 1 <u huge -> must take
    li   s0, 999
2:  li   t2, 111
    bne  s0, t2, fail

    # ---- 31: bgeu (unsigned) ----
    addi gp, x0, 31
    li   s0, 111
    li   t0, 1
    li   t1, -1
    bgeu t0, t1, 1f          # 1 >=u huge -> must NOT take
    li   s0, 222
1:  li   t2, 222
    bne  s0, t2, fail
    li   s0, 111
    li   t0, -1
    li   t1, 1
    bgeu t0, t1, 2f          # huge >=u 1 -> must take
    li   s0, 999
2:  li   t2, 111
    bne  s0, t2, fail

    # ==== Jumps ====

    # ---- 32: jal (control transfer + link value) ----
    addi gp, x0, 32
    li   s0, 111
    jal  t1, 1f
    li   s0, 999             # poison, skipped if jal works
1:  auipc t3, 0              # t3 = address of this instruction
    addi  t4, t3, -4         # expected link = address of the poison instr
    bne   t1, t4, fail
    li    t2, 111
    bne   s0, t2, fail

    # ---- 33: jalr (rs1+imm target + link value) ----
    addi gp, x0, 33
    li   s0, 111
    la   t0, 1f              # t0 = absolute address of the target label
    jalr t1, t0, 0
    li   s0, 999             # poison, skipped if jalr works
1:  addi t4, t0, -4
    bne  t1, t4, fail
    li   t2, 111
    bne  s0, t2, fail

    # ==== Upper-immediate / PC-relative ====

    # ---- 34: auipc, back-to-back difference is exactly 4 ----
    addi gp, x0, 34
    auipc t0, 0
    auipc t1, 0
    addi  t2, t0, 4
    bne   t1, t2, fail

    # ---- 35: auipc with a nonzero immediate ----
    addi gp, x0, 35
    auipc t0, 0
    auipc t1, 1              # t1 = (t0's pc + 4) + 0x1000
    addi  t2, t0, 4
    lui   t3, 1
    add   t2, t2, t3
    bne   t1, t2, fail

    # ==== Misc: fence / ecall / ebreak decode as no-ops (no CSR/trap datapath yet) ====

    # ---- 36: fence / ecall / ebreak don't corrupt state or hang ----
    addi gp, x0, 36
    li   s0, 111
    fence
    ecall
    ebreak
    li   t0, 111
    bne  s0, t0, fail

pass:
    li   a0, 1
pass_loop:
    jal  x0, pass_loop

fail:
    li   a0, 0
fail_loop:
    jal  x0, fail_loop
