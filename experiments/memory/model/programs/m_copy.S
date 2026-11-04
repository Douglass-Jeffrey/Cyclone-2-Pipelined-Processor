# Copy 4 KB to a buffer exactly 16 KB away: source and destination lines share
# a dcache index, so a direct-mapped cache misses on every access, and every
# destination eviction is a dirty write-back.  Checksum in x28.
    .globl _start
_start:
    li   x5, 0
    li   x6, 1024           # words
    li   x7, 0
init:
    sw   x7, 0(x5)
    addi x5, x5, 4
    addi x7, x7, 1
    bne  x7, x6, init
    li   x10, 0             # src
    li   x11, 0x4000        # dst, same index as src
    li   x7, 0
copy:
    lw   x9, 0(x10)
    sw   x9, 0(x11)
    add  x28, x28, x9
    addi x10, x10, 4
    addi x11, x11, 4
    addi x7, x7, 1
    bne  x7, x6, copy
halt:
    j    halt
