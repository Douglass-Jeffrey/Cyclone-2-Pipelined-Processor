# m_stream, m_copy and m_chase back to back, for one board build.
# x28 = stream sum, x30 = copy checksum, x29 = chase hops, x31 = chase's final pointer.
    .globl _start
_start:
# ---- stream: write 32 KB, read it back twice ----
    li   x5, 0
    li   x6, 8192
    li   x7, 0
s_fill:
    sw   x7, 0(x5)
    addi x5, x5, 4
    addi x7, x7, 1
    bne  x7, x6, s_fill
    li   x8, 2
s_pass:
    li   x5, 0
    li   x7, 0
s_rd:
    lw   x9, 0(x5)
    add  x28, x28, x9
    addi x5, x5, 4
    addi x7, x7, 1
    bne  x7, x6, s_rd
    addi x8, x8, -1
    bne  x8, x0, s_pass
# ---- copy: 4 KB to a buffer 16 KB away (same dcache index) ----
    li   x5, 0
    li   x6, 1024
    li   x7, 0
c_init:
    sw   x7, 0(x5)
    addi x5, x5, 4
    addi x7, x7, 1
    bne  x7, x6, c_init
    li   x10, 0
    li   x11, 0x4000
    li   x7, 0
c_copy:
    lw   x9, 0(x10)
    sw   x9, 0(x11)
    add  x30, x30, x9
    addi x10, x10, 4
    addi x11, x11, 4
    addi x7, x7, 1
    bne  x7, x6, c_copy
# ---- chase: 4096 nodes over 64 KB, two laps ----
    li   x5, 0
    li   x6, 4096*16
    li   x13, 0xFFF0
    li   x16, 1031*16
p_build:
    add  x15, x5, x16
    and  x15, x15, x13
    sw   x15, 0(x5)
    addi x5, x5, 16
    bne  x5, x6, p_build
    li   x9, 0
    li   x8, 8192
p_chase:
    lw   x9, 0(x9)
    addi x29, x29, 1
    addi x8, x8, -1
    bne  x8, x0, p_chase
    mv   x31, x9
halt:
    j    halt
