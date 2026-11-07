# Memory system optimizations

On every data-cache miss the pipeline froze for 42 cycles, most of it spent moving the line
over the SRAM's 16-bit bus. This directory holds the study that cut a miss to 12 cycles:
five changes to the SRAM controller and the data cache, each measured in RTL simulation
and checked on the DE1.

The write-up is on the [project page](https://douglass-jeffrey.github.io/projects/pipelined-processor.html).

The changes are kept as patches against `dev/` and `verif/`. They are not applied to the
design on this branch.

## Contents

| Path | What it is |
|---|---|
| `patches/` | the changes, one patch per step, and `combined.diff` with all of them |
| `harness/` | `tb_mem.v` (the board's counter testbench plus memory-stall accounting) and the scripts that run it on each design; `board_suite.py` compares the board with it |
| `harness/tb20*/`, `harness/run20.py` | the patched testbenches, for running the test suite on a patch without applying it |
| `model/` | a trace-driven cache model, checked against the RTL, with its sweep, data and kernels (`programs/m_*.S`) |
| `data/sim/` | RTL simulation counters for every design and program, code preloaded (warm) and fetched from SRAM (cold) |
| `data/board/` | board measurements: SRAM bandwidth, the memory kernels and all 19 benchmarks |
| `data/quartus*` | logic elements, timing and SRAM pin timing per design |
| `figures/plain*/`, `model/figures/plain*/` | the figures, light and dark |

## The patches

| Patch | Changes |
|---|---|
| `sram_ctl.diff` | pipelined reads and two-cycle writes in `dev/src/sram_ctl.v` |
| `tb_20ns.diff` | testbenches clocked at the board's 20 ns; **needed** with `sram_ctl.diff` |
| `c1.diff`, `c2.diff` | line-wide M4K port; fewer D-cache states (each on its own) |
| `c12.diff` | both, with the line written as it arrives |
| `c123.diff` | + write-back buffer, with testbenches that wait for it to drain |
| `combined.diff` | everything: `sram_ctl` + `c123` + 20 ns testbenches |

They apply to this branch with `git apply`. Adopting them means updating the main README's
§2.4 (D-cache FSM), §2.6 (SRAM controller) and §2.8 (miss costs).
