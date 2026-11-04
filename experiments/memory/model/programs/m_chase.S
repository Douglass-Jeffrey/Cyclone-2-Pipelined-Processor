# Pointer chase over 64 KB: 4096 nodes, one per 16-byte line, node i -> node
# (i + 1031) mod 4096.  1031 is odd, so the chain visits every node once per
# lap, and consecutive hops are 1031 lines apart.  Two laps; every hop is a
# load miss the next load depends on.  Hops in x28, final pointer in x29.
    .globl _start
_start:
    li   x5, 0              # node address
    li   x6, 4096*16        # end
    li   x13, 0xFFF0        # 4096 nodes x 16 B, wrap mask
    li   x16, 1031*16       # stride in bytes
build:
    add  x15, x5, x16
    and  x15, x15, x13
    sw   x15, 0(x5)
    addi x5, x5, 16
    bne  x5, x6, build
    li   x9, 0              # p
    li   x8, 8192           # hops (two laps)
chase:
    lw   x9, 0(x9)
    addi x28, x28, 1
    addi x8, x8, -1
    bne  x8, x0, chase
    mv   x29, x9
halt:
    j    halt
