# Branch predictor comparison

Which of the five branch predictors in `dev/src/` (bimodal, correlating, gshare, local,
tournament) works best on this CPU, and at what size? This directory runs every size the
RTL can be built at over the 19 benchmarks, confirms the results in RTL simulation and on
the DE1, and measures what each predictor costs on the FPGA.

The write-up is on the [project page](https://douglass-jeffrey.github.io/projects/pipelined-processor.html).

## How it works

1. Each benchmark runs once in the ISA simulator, and its conditional branches are saved.
2. `verif/tools/bp_model.py`, the model the test suite already holds the RTL to, replays
   those branches through 1,439 predictor configurations (about 15 minutes).
3. The configurations that matter are rerun on the RTL in Icarus and on the board to
   confirm the model, and compiled in Quartus for logic elements and timing.

## Contents

| Path | What it is |
|---|---|
| `extract_traces.py` | runs each benchmark in rvsim and saves its branches to `data/traces/` |
| `predictors.py` | the configurations: their knobs, state bits and whether the RTL can build them |
| `sweep.py` | replays the traces through every configuration: `data/sweep*.csv` |
| `breakdown.py` | splits mispredicts into libgcc multiply/divide and the programs' own code |
| `rtl_check.py`, `rtl_frontier.py` | rerun configurations on the RTL in Icarus |
| `board_check.py` | runs configurations on the DE1 and compares each readout with Icarus |
| `quartus_cost.py` | compiles configurations for logic elements, registers and timing |
| `summary.py`, `plots.py` | the headline numbers (`data/summary.txt`), `data/pareto.csv` and the figures |
| `data/` | every result as CSV, the branch traces and the raw board readouts |
| `figures/plain/`, `figures/plain_dark/` | the figures, light and dark |
