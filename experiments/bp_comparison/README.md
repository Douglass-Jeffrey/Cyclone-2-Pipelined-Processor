# Branch predictor comparison

How the five direction predictors in `dev/src/` (bimodal, correlating, gshare,
local, tournament) trade accuracy for state, across every size knob the RTL
exposes, on 19 real programs.

## Findings

MPKI = conditional-branch mispredicts per 1,000 instructions, total over the
19 programs. "As built" is the RV32I code as compiled; "without libgcc" drops
the software multiply/divide routines (see Method). Numbers are from
`data/summary.txt`. Every config quoted is one the RTL builds, except the
model-only variants in findings 6 and 7.

1. **Most mispredicts are in software multiply and divide.** 87–90% of every
   built predictor's mispredicts are inside libgcc's `__mulsi3`, `__udivsi3`
   and friends (bimodal 86.9%, tournament 89.5%), because RV32I turns every
   `a * b` into a loop with a data-dependent branch per multiplier bit
   (`mispredict_breakdown`). On this code, comparing predictors mostly means
   comparing how well they guess those bits.

2. **Any 2-bit counter beats a static guess by a wide margin; after that the
   gains are modest.** As built: always-not-taken 182.8 MPKI, backward-taken
   (BTFN) 69.5, a 32-counter bimodal (64 bits, the default) 50.2 (−28% vs
   BTFN), and the largest tournament Quartus fit at 50 MHz (3,460 bits:
   `BP_IDX_BITS` 5, `BP_HIST_BITS` 4, `BP_LHIST_BITS` 10) 39.9 (−21% vs
   bimodal). Without libgcc: BTFN 44.3, bimodal 16.1 (−64%), that tournament
   10.1 (−37%) (`pareto_as_built`, `pareto_hw_muldiv`).

3. **Bimodal stops improving at 512 counters.** 1 Kbit reaches 49.65 MPKI, and
   2,048 counters are still 49.65; the 32-counter default is within 1.1%
   (50.21). Aliasing is not what limits it on code this size: it can't learn
   patterns (`pareto_as_built`).

4. **The tournament is the best predictor at every size from 1 Kbit up.**
   Without libgcc, at 1 Kbit: tournament 11.9, local 12.5, gshare 14.0,
   correlating 14.4, bimodal 14.75. As built it is best or tied: 44.2 vs local
   44.8 at 1 Kbit, 36.27 vs 36.30 at 8 Kbit, 27.1 vs 27.7 at 32 Kbit. Tiny
   budgets split three ways don't work: at 64 bits a bimodal (50.2) beats every
   tournament (54.3), and without libgcc bimodal still leads at 256 bits
   (15.2 vs 15.6) (`pareto_*`).

5. **As built, local's lead is memorized multiplier bits.** Local keeps
   improving as its per-branch history grows: 32 slots at 8 bits 44.9 MPKI,
   at 13 bits 28.2, at 14 bits 24.7. Without libgcc the same configs give
   12.7, 11.5 and 11.6: a long history lets it recognize which multiplier
   `__mulsi3` is working on, and that is all the extra length buys
   (`heatmap_local`).

6. **XOR into the top bits matches concatenation; classic low-bit XOR is
   clearly worse.** Gshare (XOR into the top index bits) and correlating
   (concatenate pc and history) stay within 3% at every size. At the built
   size (512 counters, 4-bit history), low-bit XOR has 17% more mispredicts as
   built (54.2 vs 46.2) and 47% more without libgcc (19.8 vs 13.5). Even with
   its best history length at each size it stays 16–18% behind without libgcc
   (15.7 vs 13.5 at 1 Kbit, 14.6 vs 12.4 at 32 Kbit). On small programs, the
   nearby branches it makes collide are exactly the hot ones (`variants`).

7. **Speculative history is worth little in a 5-stage pipeline.** Without
   libgcc it saves at most ~0.3 MPKI at any size (default size: correlating
   14.01 → 13.74). As built it helps correlating by up to 1.0 MPKI at 4–8 Kbit,
   where its best history is 10–11 bits, and gshare by ~0.1. Only one branch
   can be in flight when the next one is predicted, so a history updated at
   training is at most one outcome behind (`variants`).

8. **The best global history length grows with the table.** Gshare as built:
   3 bits at 256 counters, 4 at 512, 5 at 1K, 9–10 at 2K–4K, 13 at 8K–16K;
   without libgcc 3 / 4 / 7 / 7 / 9. The built default (4 bits at 512
   counters) is the optimum for its size (`heatmap_gshare`, `heatmap_corr`).

9. **No predictor wins every program.** At 1 Kbit as built: the tournament is
   clearly best (by ≥2%) on 5 programs, bimodal on 5, correlating on 3, gshare
   on 2, local on 1, and 3 are ties. The small, short programs (statemate,
   nettle-sha256, vvadd, multiply) favor plain bimodal: fewer counters to warm
   up from reset. Weighting every program equally flattens all the curves
   (bimodal 30.6 → tournament 25.7 MPKI at 2 Kbit) (`per_program_*`,
   `pareto_*_program_mean`).

10. **In cycles the payoff is about 1% here.** Mispredicts are 4.6% of all
    cycles with the built bimodal (168,250 of ~3.63M). The 3,460-bit
    tournament above saves 34,573 cycles (0.95%); the built 1,860-bit default
    saves 21,371 (0.59%). A mispredict costs one cycle in this pipeline;
    deeper pipelines multiply all of these differences.

11. **On the EP2C20, logic and timing set the budget.** Each bit of predictor
    state costs about 2.3–2.4 LEs (bimodal from 64 to 2,048 bits: 6,310 →
    10,906 LEs for the whole SoC), and the register count rises by exactly the
    state bits plus `pred_meta`'s width. Every flat 4-Kbit table failed to fit
    (bimodal, correlating, gshare: the fitter needed 1,225–1,227 LABs of 1,172);
    the largest design that fit was a 3,843-bit tournament (13,683 LEs).
    Timing splits the predictors in two:
    - **Flat tables keep their margin.** Bimodal, correlating and gshare
      held 0.75–1.4 ns of slack (51.9–53.8 MHz) at every size that fit,
      because their lookup is not the slowest path.
    - **Two-level lookups do not.** Local's slack falls as its table of slot
      histories grows: 0.77 ns at 32 histories, 0.41 at 64, and −1.08 ns at
      128 × 10 bits (47.4 MHz, fails). A tournament with 64 histories fails the
      same way (−1.00 ns, 47.6 MHz). The slot history feeds the counter
      table, whose output feeds `next_pc`.

    The largest tournament that met 50 MHz was 3,460 bits (`BP_IDX_BITS` 5,
    `BP_HIST_BITS` 4, `BP_LHIST_BITS` 10: 13,167 LEs, 51.2 MHz)
    (`cost_les_fmax`, `data/quartus*.csv`).

12. **The models are the RTL.** `tb_bp_trace` matches the model on all 42,000
    predictions at 14 non-default shapes. The full benchmark runs at five larger
    configs (bimodal 2,048 counters; correlating 32×5; gshare 1K entries/5 bits;
    local 128×10; tournament IDX 7/G4/L10 with `BP_META_W` 34) retire exactly
    like rvsim, and their flushes minus the 46,710 jalr flushes equal the
    sweep's mispredicts exactly (`data/rtl_checks.csv`).

### Best configuration per predictor at each budget

As built / without libgcc, MPKI (lower is better); the predictor's config
in brackets, at the as-built optimum.

| Budget | Bimodal | Correlating | Gshare | Local | Tournament |
|---|---|---|---|---|---|
| 256 bits | 49.8 / 15.2 | 48.8 / 16.7 | 48.9 / 16.8 | 48.3 / 15.3 | 48.1 / 15.6 |
| 1 Kbit | 49.7 / 14.8 (512) | 46.8 / 14.4 (8×5) | 46.5 / 14.0 (256, h3) | 44.8 / 12.5 (64×8) | 44.2 / 11.9 (4,3,8) |
| 2 Kbit | 49.7 / 14.8 | 46.2 / 13.8 | 46.2 / 13.5 | 43.4 / 12.0 | 42.4 / 10.6 |
| 4 Kbit | 49.7 / 14.8 | 46.0 / 13.5 (32×5) | 45.9 / 13.2 (1K, h5) | 40.2 / 11.3 (128×10) | 39.6 / 10.1 (6,3,10) |
| 8 Kbit | 49.7 / 14.8 | 45.2 / 13.0 | 45.8 / 12.9 | 36.3 / 10.8 | 36.3 / 9.9 |
| 32 Kbit | 49.7 / 14.8 | 43.5 / 12.6 | 44.1 / 12.5 | 27.7 / 10.6 | 27.1 / 9.0 |

Defaults (dev/defines.vh): bimodal 64 bits 50.2 / 16.1, correlating and gshare
1,028 bits 46.3 / 14.0 and 46.2 / 13.5, local 768 bits 44.9 / 12.7,
tournament 1,860 bits 43.8 / 10.6.

## Method

**Workloads.** The 19 programs `benchmarks/build.py` builds (Embench, CoreMark,
riscv-tests; 3.35M instructions, 934K conditional branches), each run to
completion in `verif/tools/rvsim.py`. Two versions of every branch stream:

- **As built.** RV32I has no multiply or divide instruction, so `a * b` calls
  libgcc's `__mulsi3`, a loop with two branches per bit of the multiplier, and
  `/` calls `__udivsi3`. Those routines execute 51–94% of the instructions in
  seven of the programs (`data/programs.csv`).
- **Without libgcc multiply/divide.** The branches inside `__mulsi3`,
  `__muldi3`, `__divsi3`, `__udivsi3`, `__modsi3` and `__umodsi3` are removed,
  and their instructions dropped from the instruction count. This approximates
  the same programs on a core with the M extension, where each call is one
  instruction.

**Predictors.** Every configuration is replayed through `verif/tools/bp_model.py`,
the model the test suite already holds the RTL to: on every directed, random
and benchmark run, the RTL's flush count must equal the model's. Each program
starts from a reset predictor, as on the board. The knobs are the RTL's own
defines:

| Predictor | Knobs (dev/defines.vh) | State bits |
|---|---|---|
| Bimodal | `BP_IDX_BITS` = i | 2·2^i |
| Correlating | i, `BP_HIST_BITS` = h | 2·2^(i+h) + h |
| Gshare | i, h (table 2^(i+h), history XORed into the top h index bits) | 2·2^(i+h) + h |
| Local | i (2^i slot histories), `BP_LHIST_BITS` = l | 2^i·l + 2·2^l |
| Tournament | i, h, l (local + gshare + 2^i choosers) | sum of the parts + 2·2^i |

On this FPGA every predictor bit is a flip-flop: the caches use all 52 M4K
blocks, so the tables are built from logic elements. Quartus confirms it: each
build's register count grows by exactly the state bits plus `pred_meta`'s width.

The sweep covers 1,439 configurations per workload, up to 36 Kbit of state
(`data/sweep.csv`). Configurations the RTL can't build as written (history
under 2 bits, gshare with `BP_IDX_BITS` 0) are model-only and are marked
`rtl_buildable = False`; the Pareto lines and per-program figures use only
buildable ones. Three model-only variants isolate design choices:

- `gshare_low_variant`: classic gshare, history XORed into the low index bits;
- `corr_spec_variant`: correlating's index with speculative history;
- `gshare_late_variant`: gshare's index with history shifted at training.

**Metrics.** Mispredicts per 1,000 instructions (MPKI), total over the suite
(dominated by CoreMark, matmult and edn, which are 72% of the instructions) and
the mean of the per-program MPKI (each program counts once). A mispredict costs
one cycle in this pipeline, so mispredicts are also the cycles a predictor
loses. Two static baselines with no state: always not-taken, and backward
taken / forward not-taken (BTFN).

**Fidelity checks** (`data/rtl_checks.csv`). The model is exact at the default
and testbench sizes already. At other sizes:

- `tb_bp_trace` (every prediction of a 3,000-branch stream compared with the
  model) at 14 non-default shapes, 2–3 per predictor;
- the full benchmark run (retire trace vs rvsim, RTL flushes vs model) on
  copies of the design built at larger frontier configurations, including a
  tournament whose `pred_meta` needs `BP_META_W` 34.

**Hardware cost** (`data/quartus.csv`, `data/quartus_defaults.csv`). The whole
SoC compiled by Quartus II 13.0sp1 for the EP2C20 at a selection of frontier
configurations: logic elements, registers, slow-corner setup slack at 50 MHz.

## Reproduce

From the repository root (Python 3 with numpy and matplotlib, Icarus Verilog,
the xPack RISC-V toolchain on PATH; Quartus only for the cost step):

```
python benchmarks/build.py                               # if benchmarks/out/ is missing
python experiments/bp_comparison/extract_traces.py       # ~10 s: data/traces/
python experiments/bp_comparison/sweep.py                # ~15 min on 8 cores: data/sweep*.csv
python experiments/bp_comparison/breakdown.py            # data/breakdown*.csv
git archive HEAD dev quartus verif | tar -x -C SNAP      # a clean copy for the RTL steps
python experiments/bp_comparison/rtl_check.py --snapshot SNAP trace
python experiments/bp_comparison/rtl_check.py --snapshot SNAP bench gshare:2:8:0 ...
python experiments/bp_comparison/quartus_cost.py --snapshot SNAP --work SHORT_DIR bimodal:8:0:0 ...
python experiments/bp_comparison/plots.py                # figures/{light,dark}/*.svg|png
python experiments/bp_comparison/plots_stock.py          # the same in stock matplotlib: figures/{stock,stock_dark}/
```

Configs on the command line are `FAMILY:BP_IDX_BITS:BP_HIST_BITS:BP_LHIST_BITS`.
Quartus 13 rejects long paths, so keep `--work` short.

## Figures

Every figure is in `figures/light/` and `figures/dark/`, as SVG (text kept as
text) and 200-dpi PNG. Predictor colors are the same in every figure.

| Figure | Shows |
|---|---|
| `pareto_as_built` | Best MPKI at each state size, per predictor, programs as built; static baselines; the defaults; where Quartus stopped fitting |
| `pareto_hw_muldiv` | The same without the libgcc multiply/divide loops |
| `pareto_as_built_program_mean`, `pareto_hw_muldiv_program_mean` | The same with every program weighted equally |
| `mispredict_breakdown` | The five built predictors' mispredicts, split into libgcc multiply/divide and program code |
| `heatmap_gshare`, `heatmap_corr` | MPKI over table size x global history length; the best history for each size outlined |
| `heatmap_local` | MPKI over local history length x number of slot histories |
| `variants` | Index function (XOR into the top bits, low bits, concatenation) and history timing (speculative vs at training) |
| `per_program_1kbit`, `per_program_8kbit` | Each predictor's MPKI minus bimodal's, per program, at one budget |
| `cost_les_fmax` | Logic elements and Fmax of the whole SoC vs predictor state, from Quartus |

Data: `sweep.csv` (one row per config x workload), `sweep_per_program.csv`
(x program), `pareto.csv` (the frontier points), `breakdown*.csv`,
`rtl_checks.csv`, `quartus*.csv`, `programs.csv`, `summary.txt` (the numbers
quoted above, from `summary.py`).


## Caveats

- **Small programs.** All 19 fit in the 8 KB instruction cache, with a few
  hundred static branches each, so capacity and aliasing matter less than they
  would in large software. That favors small tables and makes the index
  function matter less; on big code, gshare's sharing and longer histories pay
  off more than here.
- **The M-extension workload is an approximation.** It removes the libgcc
  routines' branches and instructions from the same run. A real M-extension
  build would compile differently (and a hardware multiply has latency).
- **Every program starts from a reset predictor.** Short programs (statemate,
  towers, ud: under 5,000 instructions) mostly measure warm-up, which favors
  small tables; this is why the per-program-mean curves flatten early.
- **Mispredicts cost one cycle** in this 5-stage pipeline (branches resolve in
  EX, one stage after the prediction). A deeper pipeline multiplies every
  difference here.
- **Timing is one Quartus run per config**, default seed. Fmax moves by 1–2 MHz
  with placement alone, so differences that small are noise.
- **Model-only configs.** History of 1 bit and gshare with `BP_IDX_BITS` 0 are
  outside what the RTL builds as written (marked in the data); the tournament's
  chooser size is tied to `BP_IDX_BITS` as in the RTL.
- **The sweep stops at 36 Kbit.** Local's curve is still falling there as
  built, because a longer per-branch history keeps memorizing more of the
  multiplier bit patterns inside `__mulsi3`.

