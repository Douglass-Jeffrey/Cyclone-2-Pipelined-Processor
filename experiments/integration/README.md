# Integration (v3)

The `v3` design combines the two studies next door: the faster memory system from
`../memory/` and the 3,460-bit tournament predictor from `../bp_comparison/`
(`BP_IDX_BITS` 5, `BP_HIST_BITS` 4, `BP_LHIST_BITS` 10, the largest that met 50 MHz).
This directory holds the checks that the combined design runs as both studies predicted.

## Contents

| Path | What it is |
|---|---|
| `rtl_benchmarks.py` | all 19 benchmarks on the RTL in Icarus: retirement vs rvsim, flushes vs the predictor model and the sweep |
| `data/rtl_benchmarks.csv` | its result, per program |
| `data/board/` | the DE1 runs from `../bp_comparison/board_check.py`: `builds.csv`, `runs.csv` (all 16 readout words, board and Icarus) and each raw JTAG readout |
| `data/quartus/` | the board build's fit and timing summaries and its worst setup paths |
