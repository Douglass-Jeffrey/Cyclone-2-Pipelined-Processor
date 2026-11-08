# Memory system optimizations

On every data-cache miss the pipeline froze for 42 cycles, most of it spent moving the line
over the SRAM's 16-bit bus. This directory holds the study that cut a miss to 12 cycles:
five changes to the SRAM controller and the data cache, each measured in RTL simulation
and checked on the DE1.

The write-up is on the [project page](https://douglass-jeffrey.github.io/projects/pipelined-processor.html).

All five changes are now part of the design (`dev/src/sram_ctl.v`, `dcache.v` and
`cache_ram.v`, with the testbenches at the board's 20 ns). The study measured them as
patches against the original design, one per step. Those live in the `v2` branch:
`git show v2:experiments/memory/patches/<name>.diff` (`sram_ctl`, `tb_20ns`, `c1`, `c2`,
`c12`, `c123` and `combined`).

## Contents

| Path | What it is |
|---|---|
| `harness/` | `tb_mem.v` (the board's counter testbench plus memory-stall accounting) and the scripts that run it on each design; `board_suite.py` compares the board with it |
| `model/` | a trace-driven cache model, checked against the RTL, with its sweep, data and kernels (`programs/m_*.S`) |
| `data/sim/` | RTL simulation counters for every design the study measured and every program, code preloaded (warm) and fetched from SRAM (cold); `base` is the original design |
| `data/board/` | board measurements: SRAM bandwidth, the memory kernels and all 19 benchmarks |
| `data/quartus*` | logic elements, timing and SRAM pin timing per design |
| `figures/plain*/`, `model/figures/plain*/` | the figures, light and dark |
