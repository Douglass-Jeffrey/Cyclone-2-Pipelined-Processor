# Cache organization study (model)

**Question.** Within this design's budget of 52 M4K blocks and its 16-bit asynchronous
SRAM, which cache organization minimizes memory stall cycles, and how does the answer
depend on how fast the SRAM controller moves a line?

**Method.** Every load, store and instruction fetch of each program is recorded with the
RV32I reference model (`verif/tools/rvsim.py`), in program order, which is the order the
in-order pipeline's caches see them. A trace-driven simulator replays those traces
through each organization: write-back, write-allocate for the data cache; read-only for
the instruction cache; LRU replacement when associative. A cycle model, derived state by
state from `dcache.v`, `icache.v` and `sram_ctl.v`, converts the misses into stall cycles.

**Workloads.** The 19 programs in `benchmarks/out/` ("the suite"), plus three memory
kernels: `m_stream` (a 32 KB array written once, then read twice), `m_copy` (a copy
between two buffers 16 KB apart) and `m_chase` (a pointer chase over 64 KB). "Warm"
means the code is preloaded into the I-cache, as on the board. "Cold" means the code is
fetched from SRAM, as it would be with a program loader.

## Validation

At today's organization (16 KB direct-mapped D-cache, 8 KB I-cache, 16-byte lines) the
simulator reproduces the RTL counter twin exactly on all 22 programs: D-cache misses,
their load/store split, write-backs and cold-mode I-cache misses. The cycle model
reproduces the measured warm D-cache stall cycles exactly (42 per clean miss, 82 per
dirty miss), and its cold-mode total cycles are within 1.31% of the RTL's on the worst
program. The I-cache penalty is calibrated at 41.07 cycles, 0.93 below the 42-cycle FSM,
because the back end keeps draining during an I-cache miss.

## Findings

1. **Today, the D-cache stalls the pipeline for 4.35% of all cycles** (164,806 of
   3,790,660); the per-program mean is 16.7%, and small programs are the worst (vvadd
   66.5%, median 58.2%). The suite's 3,923 misses are 3,853 store misses and 70 load
   misses, with one write-back. The count doesn't change from 16 to 32 KB or from 1 to 4
   ways, so every miss is compulsory: the first touch of each line, mostly the
   benchmarks' data-init stores and output arrays. *Fig. 4, Fig. 2*
2. **Controller speed is the biggest lever, and needs no cache change.**
   `WAIT_CYCLES = 1` (3 cycles per beat) cuts stalls 19%, to 133,414. Burst reads (1 cycle
   per beat) cut them 55%, to 74,569 (2.02% of cycles). *Fig. 1, Fig. 3*
3. **Bigger lines halve the misses but hardly the stalls, unless beats are fast.** Misses
   halve with each doubling (3,923 → 1,993 → 1,016) because the suite touches data
   sequentially, but each miss moves proportionally more beats. At 4 cycles a beat, stalls
   fall only 5.6% (32 B) and 7.4% (64 B); with burst reads, 17% and 25%. Random access
   pays for long lines: with burst reads, `m_chase` is 21% (32 B) and 73% (64 B) slower
   than at 16 B. *Fig. 1, Fig. 2*
4. **Associativity does nothing for the suite**, because it has no conflict misses. It
   rescues the conflict case: in `m_copy` the two buffers share every index, and 2-way LRU
   cuts its misses 2,048 → 512 and its stalls by 83%. The cost is 256–768 LRU registers
   and a way mux in the load path, a timing cost the model doesn't charge. *Fig. 2*
5. **A line-wide fill port (mixed-width M4K port B) helps more as beats get faster.** It
   saves L/4 − 1 cycles on every fill and on every victim read: −7% at today's speed, −16%
   with burst reads, −23% with burst reads and 32 B lines, because it trims a fixed cost
   whose share grows as the beats shrink. *Fig. 1, Fig. 3*
6. **Write-validate removes 58% of the suite's line fetches.** 2,295 of the 3,923 fetches
   are word stores to lines that haven't been read yet. With per-word valid bits they can
   allocate without reading SRAM, which halves the stalls even at today's speed (164,806
   → 80,467). The cost is 4,096 valid bits for 16 KB. At 16 B lines they don't fit the M4K
   budget (53 of 52 blocks); at 32 B lines they do (51 of 52), because the tag RAM
   shrinks to one block and the dirty bit plus 8 word-valid bits fit one 512×9 block.
   *Fig. 3*
7. **Best feasible design:** burst reads, a line-wide fill port, 32 B lines and
   write-validate, still 16 KB and direct-mapped (51 of 52 M4Ks). Stall cycles fall to
   24,944 (0.68% of cycles), an 85% reduction. Total suite cycles fall 3.7% (3,790,660 →
   3,650,798), and the per-program mean stall falls from 16.7% to 2.4% (vvadd 66.5% →
   6.7%, median 58.2% → 5.2%). 64 B lines reach 0.55%, but cost `m_chase` 40% more than
   32 B and need 512-bit line buffers. *Fig. 3, Fig. 4*
8. **With a program loader, I-cache misses cost as much as D-cache misses.** Fetching code
   from SRAM adds 4,780 I-cache misses, all compulsory: the count is identical for 1 or 2
   ways and for 8 or 16 KB, because the suite's code fits 8 KB by construction. Total
   memory stall is 9.06% today (I-cache 196K cycles ≈ D-cache 165K), 4.25% with burst
   reads, 2.79% adding a line-wide port and 32 B lines, and 2.41% with 64 B lines.
   *Fig. 5*
9. **The M4K budget rules out a bigger D-cache, not a different split.** A 32 KB D-cache
   needs 64 data blocks on its own. An 8 KB D-cache with a 16 KB I-cache fits exactly (52
   of 52), but buys nothing here and raises D-cache misses by 11% (4,367). Every 16 KB
   organization with 32 or 64 B lines frees one block. *data/m4k.csv*

## M4K budget (selected organizations; I-cache 8 KB direct-mapped with the same line size)

| D-cache | Line | Ways | Write-validate | D-cache M4Ks (data + tag + dirty) | Total | Fits |
|---|---|---|---|---|---|---|
| 16 KB | 16 B | 1 | no | 32 + 2 + 1 = 35 | 52 | yes (today) |
| 16 KB | 16 B | 1 | yes | 32 + 2 + 2 = 36 | 53 | **no** |
| 16 KB | 32 B | 1 | yes | 32 + 1 + 1 = 34 | 51 | yes |
| 16 KB | 64 B | 1 | yes | 32 + 1 + 1 = 34 | 51 | yes |
| 16 KB | 16 B | 2 | no | 32 + 2 + 1 = 35 | 52 | yes (+512 LRU registers) |
| 16 KB | 16 B | 4 | no | 32 + 2 + 1 = 35 | 52 | yes (+768 LRU registers) |
| 32 KB | 16 B | 1 | no | 64 + 2 + 1 = 67 | 84 | no |

The full grid is in `data/m4k.csv`. An M4K holds 4 Kbit, shaped anywhere from 4096×1 to
128×36. Each way's data must be readable 32 bits at a time, and every way's tag must be
readable at once.

## Cycle model and caveats

For a line of L bytes, B = L/2 beats move on the 16-bit SRAM bus and L/4 words go through
today's 32-bit M4K port. A fill costs 6 + B·c_read + latency + L/4 cycles. A write-back
adds (L/4 + 1) + 3 + B·c_write. An I-cache miss costs the fill minus 0.93. With a
line-wide port, the L/4 terms become 1. The three controller speeds:

- **Today:** c_read 4, c_write 4.
- **`WAIT_CYCLES = 1`:** c_read 3, c_write 3.
- **Burst reads:** c_read 1, plus 1 cycle of latency per line; c_write 3.

Caveats:

- The burst numbers are a model; the RTL controller built alongside this study is
  measured in `experiments/memory/README.md`. Write speed barely matters for the suite,
  which has one write-back.
- Associative caches are charged the same penalties as direct-mapped ones; their way
  select and LRU timing aren't modelled.
- Line buffers grow with the line (L·8 bits in each cache and twice that in `sram_ctl`),
  an LE cost the model doesn't count.
- Write-validate uses per-word valid bits. A byte or halfword store to a word that isn't
  valid yet fetches the line and merges. A partially valid dirty line is charged as a
  full-line write-back; a real design writes only its valid words, using the SRAM's UB/LB
  byte enables.
- The suite is dominated by compulsory misses by construction: its code must fit the 8 KB
  preload and its data is small. The kernels show what bigger working sets do.

## Figures (`figures/`, each as SVG and PNG, in light and `_dark` variants)

- `fig1_controller_speed`: stall % vs line size for the three controller speeds, with a
  32-bit and a line-wide fill port.
- `fig2_associativity`: misses vs line size for 1, 2 and 4 ways, for the suite and each
  kernel.
- `fig3_path`: suite stall cycles as one optimization is added at a time.
- `fig4_per_program`: stall % per program at three design points.
- `fig5_cold_start`: cold-start stall (code from SRAM), split into I-cache and D-cache.

Colors are the dataviz reference palette's first three categorical slots, validated
all-pairs in both modes: worst CVD ΔE 9.2 light and 9.4 dark, worst normal-vision ΔE 24.0
and 20.9. Light-mode aqua is 2.74:1 against the surface, so it always carries direct
labels. The CSVs in `data/` are the table view.

## Rerun

    python experiments/memory/model/traces.py      # traces -> build/cache_model_traces/ (gitignored)
    python experiments/memory/model/validate.py    # must print ALL MATCH
    python experiments/memory/model/sweep.py       # data/dcache_counts.csv, data/icache_counts.csv
    python experiments/memory/model/analyze.py     # data/summary_dcache.csv, summary_cold.csv, per_program.csv, m4k.csv
    python experiments/memory/model/figures.py     # figures/

`data/rtl_base_warm.json` and `data/rtl_base_cold.json` are the RTL counter twin's
measurements of today's design: the ground truth for `validate.py` and for the model's
calibration. The kernels' sources are in `programs/`.
