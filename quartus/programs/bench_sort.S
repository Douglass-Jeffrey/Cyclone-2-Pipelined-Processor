# Benchmark: insertion sort of 64 words held in data memory.
#
# Picked because it is dominated by exactly the things a pipeline is supposed
# to be good or bad at -- a data-dependent inner loop, a load feeding a compare
# one instruction later (load-use interlock), and a branch whose direction
# changes with the data (every mispredict is a flush today, since there is no
# predictor yet).  That makes it a useful "before" number to compare against
# once branch prediction lands.
#
# Reports, per the wrapper's x28..x31 convention:
#   x28  checksum of the sorted array (sum of a[i]*(i+1), wraps mod 2^32)
#   x29  number of swaps performed
#   x30  number of elements sorted
#   x31  0 if the array verified as sorted, else (index that failed) + 1.
#        The +1 matters: a failure at index 0 used to report 0 as well, which
#        is indistinguishable from success.  x28 (the checksum) then shows how
#        far the check got -- 0 means it stopped at the very first element.
#
# Data memory here is 256 words; the array lives at words 0..63.
    .equ N, 64

    .globl _start
_start:
    # ---- fill the array with a deterministic pseudo-random sequence ----
    # x = x*1103515245 + 12345, take bits [20:13] -- a cheap LCG, and using it
    # means the input is identical in simulation and on the board.
    addi x5,  x0, 1             # lcg state
    addi x6,  x0, 0             # index
    addi x7,  x0, N
    li   x18, 1103515245
    li   x19, 12345
fill:
    mul_lcg:                    # no M extension: shift-add multiply
    addi x20, x0, 0             # product
    addi x21, x0, 0             # bit counter
    add  x22, x5,  x0           # multiplicand copy
mulloop:
    andi x23, x18, 1
    beq  x23, x0, mulskip
    add  x20, x20, x22
mulskip:
    slli x22, x22, 1
    srli x18, x18, 1
    addi x21, x21, 1
    bne  x18, x0, mulloop
    li   x18, 1103515245        # restore multiplier for the next round
    add  x5,  x20, x19          # x5 = x5*A + C
    srli x24, x5,  13
    andi x24, x24, 255          # value in 0..255
    slli x25, x6,  2
    sw   x24, 0(x25)
    addi x6,  x6,  1
    blt  x6,  x7,  fill

    # ---- insertion sort ----
    addi x29, x0, 0             # swap count
    addi x8,  x0, 1             # i = 1
outer:
    bge  x8,  x7,  sorted
    slli x9,  x8,  2
    lw   x10, 0(x9)             # key = a[i]
    addi x11, x8,  -1           # j = i-1
inner:
    blt  x11, x0,  place
    slli x12, x11, 2
    lw   x13, 0(x12)            # a[j]  -- load feeding the compare below
    ble  x13, x10, place
    addi x14, x12, 4
    sw   x13, 0(x14)            # a[j+1] = a[j]
    addi x29, x29, 1
    addi x11, x11, -1
    j    inner
place:
    addi x15, x11, 1
    slli x15, x15, 2
    sw   x10, 0(x15)
    addi x8,  x8,  1
    j    outer

    # ---- verify sorted, and checksum ----
sorted:
    addi x31, x0, 0             # 0 = verified
    addi x28, x0, 0             # checksum
    addi x6,  x0, 0
    addi x16, x0, 0             # previous element
check:
    slli x9,  x6,  2
    lw   x17, 0(x9)
    blt  x17, x16, badorder
    add  x16, x17, x0
    addi x26, x6,  1            # weight = i+1
    # checksum += a[i] * (i+1), again by shift-add
    addi x27, x0,  0
    add  x22, x17, x0
    add  x21, x26, x0
csloop:
    andi x23, x21, 1
    beq  x23, x0,  csskip
    add  x27, x27, x22
csskip:
    slli x22, x22, 1
    srli x21, x21, 1
    bne  x21, x0,  csloop
    add  x28, x28, x27
    addi x6,  x6,  1
    blt  x6,  x7,  check
    j    done
badorder:
    addi x31, x6, 1             # (index that failed) + 1, never 0
done:
    add  x30, x7, x0            # elements sorted
halt:
    j    halt
