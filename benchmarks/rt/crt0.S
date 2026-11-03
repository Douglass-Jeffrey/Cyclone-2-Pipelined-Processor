# Start-up for C benchmarks: stack at the top of the data region, rebuild
# .data/.rodata with stores (loads can't reach code memory), run main, then
# halt on `j .` with main's return in x31 (0 = the benchmark's self-check passed).
    .section .text.start, "ax"
    .globl _start
_start:
    li   sp, 0x3FFF0
    call __data_init
    call main
    mv   x31, a0
    li   x28, 0
    li   x29, 0
    li   x30, 0
halt:
    j    halt
