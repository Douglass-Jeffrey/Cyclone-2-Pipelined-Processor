# Write a 32 KB array (twice the dcache), then read it back twice, summing into x28.
# Store misses on fresh lines, then capacity misses whose victims are dirty.
    .globl _start
_start:
    li   x5, 0
    li   x6, 8192           # words
    li   x7, 0
fill:
    sw   x7, 0(x5)
    addi x5, x5, 4
    addi x7, x7, 1
    bne  x7, x6, fill
    li   x8, 2              # read passes
pass:
    li   x5, 0
    li   x7, 0
rd:
    lw   x9, 0(x5)
    add  x28, x28, x9
    addi x5, x5, 4
    addi x7, x7, 1
    bne  x7, x6, rd
    addi x8, x8, -1
    bne  x8, x0, pass
halt:
    j    halt
