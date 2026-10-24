# D-cache evictions.  0x0000, 0x4000, 0x8000 and 0x3C000 all map to the same
# cache line (index 0) with different tags, so each access below throws out the one before:
# dirty lines must be written back and come home intact, byte and halfword
# stores must merge into fetched lines, a load's data must survive the freeze
# while the store behind it misses, and an address past the 256 KB data
# region must wrap.  The run ends with lines both in SRAM and dirty in the
# cache, so the final memory check reads through both.
#
# EXPECT x4 = 0x11223344
# EXPECT x5 = 0x0000a500
# EXPECT x6 = 0x11223344
# EXPECT x7 = 0x0000a500
# EXPECT x8 = 0x33440000
# EXPECT x11 = 0x11223344
# EXPECT m0 = 0x11223344
# EXPECT m4096 = 0x0000a500
# EXPECT m4097 = 0x11223344
# EXPECT m8192 = 0x11223344
# EXPECT m8194 = 0x0000a500
# EXPECT m61443 = 0x33440000
# EXPECT m65535 = 0x112233a5
    .globl _start
_start:
    li   x1, 0x4000
    li   x2, 0x8000
    li   x3, 0x3C000
    li   x20, 0x11223344
    li   x21, 0xA5

    sw   x20, 0(x0)         # line 0 tag 0: fill, then dirty
    sb   x21, 1(x1)         # tag 1: writes back tag 0
    lw   x4, 0(x0)          # writes back tag 1, refetches tag 0
    lw   x5, 0(x1)          # tag 0 is clean: no write-back

    # back-to-back stores, each evicting the dirty line before it
    sw   x4, 4(x1)          # hit
    sw   x5, 8(x2)          # writes back tag 1
    sh   x4, 14(x3)         # writes back tag 2; halfword merged into the fetched line

    # the store's miss freezes the pipe while the load's data waits in WB
    lw   x6, 4(x1)
    sw   x6, 0(x2)
    lw   x7, 8(x2)          # hit
    lw   x8, 12(x3)         # writes back tag 2

    # the last line of the data region, reached directly and by wrapping
    li   x9, 0x3FFF0
    sw   x20, 12(x9)
    li   x10, 0x7FFFC       # wraps to 0x3FFFC
    lw   x11, 0(x10)
    sb   x21, 0(x10)
halt:
    j halt
