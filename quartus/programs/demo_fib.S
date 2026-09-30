# Board demo program for the pipelined core.
#
# Runs forever so the display keeps moving in free-run mode.  The loop body is
# chosen so every hazard path the core implements is exercised on real
# hardware, not just in simulation:
#
#   add x5, x1, x2    reads two registers written 1 and 2 instructions back
#                     -> EX forwarding from MEM and from WB
#   sw  x5, 0(x4)     store data produced by the add right before it
#   lw  x6, 0(x4)     ...and read straight back
#   add x7, x6, x6    consumes the load immediately -> load-use interlock,
#                     the one case that costs a bubble
#   bne                taken every iteration -> a squash every time round
#
# x10 counts completed iterations, so with SW7:5=010 (write-back data) you can
# watch it climb.  Fibonacci overflows 32 bits after ~47 iterations and simply
# wraps; that is expected and harmless.
    .globl _start
_start:
    addi x1,  x0, 0         # fib a
    addi x2,  x0, 1         # fib b
    addi x4,  x0, 0         # byte offset into data memory
    addi x10, x0, 0         # iteration counter
    addi x11, x0, 1         # constant 1, so the loop test is register-register

loop:
    add  x5, x1, x2         # forwarding: x1 and x2 are both recent
    sw   x5, 0(x4)          # store data from the instruction right before
    add  x1, x2, x0
    add  x2, x5, x0
    lw   x6, 0(x4)          # read it straight back
    add  x7, x6, x6         # load-use: this one stalls a cycle
    addi x4, x4, 4
    andi x4, x4, 0x7c       # wrap inside the first 32 words of data memory
    add  x10, x10, x11      # iteration count
    bne  x11, x0, loop      # always taken -> a flush every iteration
