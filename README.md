# Pipelined RV32I Processor on the Cyclone II (DE1)

A 5-stage pipelined RV32I datapath with forwarding, a load-use interlock, a
2-bit branch predictor, and an 8 KB instruction cache + 16 KB data cache in
front of the board's 512 KB SRAM. It runs at 50 MHz on the Altera Cyclone II
FPGA Starter Development Board (DE1, EP2C20F484C7) and is checked against a
Python reference model by directed, random and unit testbenches.

| | |
|---|---|
| ISA | RV32I (no CSRs, traps or interrupts) |
| Pipeline | IF, ID, EX, MEM, WB, in order |
| Clock | 50 MHz board oscillator; Fmax ~52–54 MHz depending on placement |
| Caches | 8 KB icache + 16 KB dcache, direct mapped, 16 B lines, all 52 M4Ks |
| Main mem | On-board IS61LV25616 SRAM, 256K x 16 (512 KB) |
| Resources | ~6,300 / 18,752 LEs, 52 / 52 M4Ks |
| Tools | Icarus Verilog, xPack RISC-V GCC, Python 3, Quartus II 13.0sp1 |

---

## 1. Repository layout

```
Pipelined_processor/
├── dev/
│   ├── defines.vh            opcodes, ALU codes, mux select codes
│   ├── rtl_sources.txt       the RTL file list (read by the test runners and bench.py)
│   └── src/
│       ├── pipeline.v        the datapath; also hooks up the caches, arbiter and sram_ctl
│       ├── ctl.v             main decode and control
│       ├── imm_gen.v         immediate generator
│       ├── alu.v
│       ├── regfile.v         32 x 32, write-through
│       ├── hazard_unit.v     load-use interlock
│       ├── forwarding_unit.v MEM/WB -> EX forwarding
│       ├── branch_predictor.v 2-bit counters, predicts in ID
│       ├── icache.v          8 KB instr cache
│       ├── dcache.v          16 KB data cache
│       ├── cache_ram.v       M4K templates: sdp_ram, tdp_ram
│       ├── mem_arbiter.v     icache / dcache -> sram_ctl
│       ├── sram_ctl.v        board SRAM controller
│       └── imem.v, dmem.v    retired by the caches (kept, still unit tested)
├── verif/
│   ├── run_directed_tests.py, run_randomized_tests.py, run_unit_tests.py
│   ├── tb/                   tb_pipeline.v, tb_bench.v, tb_dcache.v, tb_branch_predictor.v,
│   │                         tb_sram_ctl.v, tb_sram_memtest.v, tb_imem.v, tb_dmem.v, sram_model.v
│   ├── test_scripts/         directed tests (*.S)
│   ├── test_lists/           default.txt, stall_only.txt, bp_only.txt, program.txt
│   └── tools/                harness.py, rvsim.py (reference model), randgen.py, ...
├── quartus/
│   ├── soc_top.v             board wrapper: clocking, reset, halt, counters, display, JTAG
│   ├── soc_top.qpf/.qsf/.sdc Quartus project, settings and pins, timing constraints
│   ├── assign_pins.tcl       pin assignments, if Quartus drops them from the .qsf
│   ├── bench.py              assemble a program, predict the board's numbers, compare with the board
│   ├── read_results.tcl      read the board over JTAG
│   ├── programs/             bench_sort.S, demo_fib.S, program.S
│   └── sram_test/            standalone board SRAM memory test project (sram_memtest.v + top)
└── build/                    test and bench output, one folder per run
```

The RTL is never copied: the Quartus project and every testbench build from
`dev/src`, so simulation and synthesis always use the same source.

---

## 2. Pipeline

```
        IF              ID                  EX                    MEM                 WB
  next_pc ──► icache ──► decode, regfile ──► forwarding, ALU, ───► dcache hit check, ──► load align,
              (M4K)      branch predictor    branch compare,       store write          wb mux,
                         hazard unit         redirect, wb value                         regfile write
```

### 2.1 Stages

| Stage | What happens |
|---|---|
| IF | `next_pc` picks the fetch address and goes straight into the icache. The M4K blocks latch the addr and present the instr on the next CC, so the instr arrives in ID. |
| ID | `ctl.v` decodes, `imm_gen.v` builds the immediate, the regfile is read. The branch predictor predicts the instr in ID. The hazard unit checks for a load-use RAW. The icache hit check happens here. |
| EX | Forwarding muxes pick the operands. ALU, a dedicated branch comparator and a dedicated JALR adder. Branch mispredicts and JALR redirect the front end from here. The write-back value is resolved here for everything except loads. The dcache tag lookup starts here, addressed by the ALU result. |
| MEM | dcache hit check. A store writes its byte lanes and sets the line's dirty bit. A load is latched and its data comes out in WB. A miss freezes the pipeline. |
| WB | Load data out of the dcache is aligned (LB/LH/LW/LBU/LHU). The WB mux picks load data or the value resolved in EX, then the regfile is written. |

### 2.2 next_pc

`next_pc` is redirected if there's a branch or jump, else if there's a stall
we send the same PC again, else we take the prediction, else increment by 4 to
get the next instr:

```
next_pc = redirect from EX   ? redirect target      (mispredict or jalr)
        : stall              ? if_id_pc             (load-use, or icache miss)
        : predicted taken    ? pc + imm             (branch predictor / jal in ID)
        :                      if_id_pc + 4
```

The branch compare in EX arrives last, and it sits on the crit path. So in
`pipeline.v` `next_pc` is built for both outcomes of the compare
(`next_pc_t`, `next_pc_n`, marked `(* keep *)` so Quartus doesn't merge them
back) and the compare result only picks between them in the final 2:1 mux.

### 2.3 Hazards and forwarding

| Hazard | Handled by | Cost |
|---|---|---|
| RAW between ALU-type producers and consumers | Forwarding from MEM or WB into EX (`forwarding_unit.v`). MEM wins when both match. | 0 cycles |
| RAW from a load to the very next instr | Load-use interlock (`hazard_unit.v`): hold IF/ID, bubble into EX | 1 cycle |
| Producer in WB, consumer in ID | Regfile write-through | 0 cycles |
| Store right behind a load that produces its store data | Load->store forwarding in MEM: if the prev cycle was a valid read and rd == rs2, store the data we just loaded | 0 cycles |
| Branch mispredict, JALR | Redirect from EX, the instr in ID becomes a bubble | 1 cycle |

The only time we need a stall/bubble is when a consuming reg instr is behind a
load. Each forwarding source and every side effect is gated by the stage's
`valid` bit, so bubbles never do anything.

### 2.4 Branch prediction

Branch prediction takes place in ID, the actual branch resolves in EX.

- 32 two-bit saturating counters, indexed by `pc[6:2]`, untagged. They reset to
  `01` (weakly not taken).
- A conditional branch in ID is predicted with its counter. Its target
  (`pc + immB`) is computed in ID, so a correctly predicted taken branch costs
  0 cycles.
- JAL is always predicted taken in ID.
- JALR resolves in EX (rs1 isn't forwarded into ID).
- Every conditional branch trains its counter when it resolves in EX.
- A mispredict in either direction redirects from EX and costs 1 cycle.

Predicting in ID instead of IF keeps the predictor off the
redirect -> next_pc crit path (see the notes at the top of
`branch_predictor.v`).

### 2.5 Clock enable and pipeline freeze

Every pipeline register, the regfile and the predictor update only when
`pipe_en` is high:

```
pipe_en = clk_en && !dc_busy
```

- `clk_en` comes from the board's speed setting.
- `dc_busy` is the dcache saying a MEM access missed, or that its reset sweep
  hasn't finished.

When `pipe_en` is low every stage holds, valid bits included, so nothing is
lost or repeated. The cache controllers, the arbiter and `sram_ctl` run on
every clock edge, so a miss keeps making progress while the pipeline is
frozen.

### 2.6 ISA coverage

All of RV32I except the system parts: FENCE, ECALL and EBREAK execute as NOPs,
and there are no CSRs, traps or interrupts. Programs are assembled at address
0, end with `j .` (`0x0000006F`), and leave their results in x28–x31.

---

## 3. Memory system

The on-board SRAM is main mem and the M4Ks are the caches.

```
   IF/ID                                   EX/MEM/WB
     │                                         │
 ┌── icache (8 KB) ──┐               ┌── dcache (16 KB) ──┐
 │ tag+valid 512x6   │               │ tag+valid 1024x5   │
 │ data 2048x32      │               │ dirty     1024x1   │
 │ refill controller │               │ 4 lanes 4096x8     │
 └────────┬──────────┘               │ controller         │
          │ read lines               └────────┬───────────┘
          │                                   │ read/write lines
          └──────────► mem_arbiter ◄──────────┘   (dcache wins a tie)
                            │
                        sram_ctl  (16-byte line = 8 x 16-bit beats)
                            │
               SRAM chip 256K x 16 = 512 KB
               0x00000–0x3FFFF  instr mem (256 KB)
               0x40000–0x7FFFF  data mem  (256 KB)
```

### 3.1 Memory scheme

The SRAM is split in half: the low 256 KB is instr mem, the high 256 KB is
data mem. Both have an 18-bit physical address space. The pipeline adds the
19th SRAM address bit (0 for instr, 1 for data) on the way into the arbiter,
so each cache only ever sees its own half. Addresses past 256 KB wrap. Code
and data are separate address spaces, like the old imem and dmem, so a store
can never overwrite an instr.

| Region | SRAM bytes | CPU address used | Cache |
|---|---|---|---|
| instr mem | 0x00000–0x3FFFF | `pc[17:0]` | icache |
| data mem | 0x40000–0x7FFFF | `addr[17:0]` | dcache |

### 3.2 Cache address breakdown

Both caches use 16-byte lines, so the bottom 4 bits are the offset into the
line.

```
icache  (512 lines)          17      13 12            4 3    2 1    0
                             [ tag (5) ][  index (9)   ][word ][byte]

dcache  (1024 lines)         17    14 13              4 3    2 1    0
                             [tag (4)][   index (10)   ][word ][byte]
```

- **index** picks the line, both its tag and valid entry and its words in the
  data ram.
- **tag** tells which of the 2^tag lines in mem that map to this index is
  currently cached.
- The data ram is addressed by `{index, word}`, which is just the low address
  bits, so the data ram is laid out like a small plain memory.

### 3.3 icache

8 KB, direct mapped, read only.

| RAM | Shape | M4Ks | Port A | Port B |
|---|---|---|---|---|
| tag and valid bit sdp ram | 512 x 6 `{valid, tag}` | 1 | CPU read, `next_pc[12:4]` | refill write |
| data ram | 2048 x 32 | 16 (2048 x 2 each) | CPU read, `next_pc[12:2]` | refill write |

- **Lookup:** `next_pc` addresses both rams at once. In ID the icache compares
  the tag with `if_id_pc[17:13]`.
- **Miss:** handled like a load-use stall. IF/ID holds and EX gets a bubble,
  while the instrs already in EX, MEM and WB keep going. The controller
  invalidates the line, reads it from SRAM, writes the 4 words, then the tag,
  and the held fetch hits. About 45 cycles.
- **Warm boot (`WARM = 1`):** the data ram powers up holding `program.hex`
  (the first 8 KB of code) and every tag powers up valid. A program up to
  8 KB runs straight from the bitstream with no image in SRAM. A reset does
  not invalidate the icache, so KEY0 reruns the program.

### 3.4 dcache

16 KB, direct mapped, write-back, allocate on store miss (a store that misses
fetches the line first, then writes it).

| RAM | Shape | M4Ks | Port A (register <-> dcache) | Port B (dcache <-> sram) |
|---|---|---|---|---|
| tag and valid bit sdp ram | 1024 x 5 `{valid, tag}` | 2 | CPU read, EX ALU result `[13:4]` | controller write |
| dirty bit sdp ram | 1024 x 1 | 1 | — | store hit sets, refill clears; controller reads |
| data ram, 4 lanes of 8-bit tdp rams | 4 x (4096 x 8) | 32 (4096 x 1 each) | loads and stores, `ex_mem_alu_result[13:2]`, enable `pipe_en` | refill writes, write-back reads |

**Byte lanes.** Lane k holds byte k of every word. A load reads all 4 lanes
and the WB alignment picks the byte or halfword. A store enables only the
lanes it writes (`st_be` from funct3 and `addr[1:0]`), so byte and halfword
stores take one cycle with no read-modify-write.

**Timing of a hit.**

| Stage | dcache work |
|---|---|
| EX | tag and valid read with the ALU result, a stage early |
| MEM | `hit = valid && tag match`. A store writes its lanes and sets the dirty bit. |
| WB | load data out of the lanes, aligned |

**Miss.** `busy` goes high in MEM, `pipe_en` goes low, and every stage
freezes. The load or store stays in MEM until the line is in.

**Controller FSM.** A hit never leaves IDLE:

| State | Job | Next |
|---|---|---|
| S_INIT | After reset: walk all 1024 lines, clear valid and dirty. With `CLEAR_SRAM = 1` (board), also zero the whole data mem in SRAM (~12 ms). | S_IDLE |
| S_IDLE | Wait for a MEM access that misses | S_CHECK |
| S_CHECK | The victim's dirty bit is read this cycle | dirty: S_WBRD, clean: S_FILL |
| S_WBRD | Read the victim's 4 words through port B into the line buffer | S_WBREQ |
| S_WBREQ | Write the victim line to SRAM | S_FILL on ack |
| S_FILL | Read the missing line from SRAM into the line buffer | S_FILLWR on ack |
| S_FILLWR | Write the 4 words into the lanes through port B | S_TAG |
| S_TAG | Write `{valid = 1, tag}` and clear dirty. The tag goes last, so a half-written line is never valid. | S_DONE |
| S_DONE | Force a hit so the frozen access completes | S_IDLE once the pipeline moves |

The dirty bit is read after the miss, not a stage early like the tag, because
a store hit just ahead could be setting that same bit on the same edge.

**Implementation note.** Quartus 13 won't infer a true dual-port M4K with a
clock enable, so `tdp_ram` in `cache_ram.v` instantiates `altsyncram` directly
for synthesis, with port B on its own clock enable, and keeps a behavioural
model for iverilog.

### 3.5 Memory arbiter

`sram_ctl` moves one line at a time, so `mem_arbiter.v` picks whose request
goes:

- The dcache wins a tie: its miss freezes the whole pipeline, an icache miss
  only holds the front end.
- A grant lasts until its ack.
- The arbiter adds the region bit and routes the ack back to the owner.
- The read data from `sram_ctl` goes to both caches; only the one that got
  the ack takes it.

### 3.6 SRAM controller

The SRAM is a 10 ns asynchronous part with a 16-bit data bus, so a 16-byte
line is 8 beats. Each beat is SETUP (1 cycle), PULSE (`WAIT_CYCLES` = 2
cycles) and HOLD (1 cycle):

- **Reads:** OE_N stays low for the whole line and the data is sampled 3 cycles
  after the address.
- **Writes:** the address and data are stable a full cycle before WE_N falls and
  a full cycle after it rises.
- **Pins:** every pin comes straight from an I/O-cell register.
- **Byte enables:** UB_N and LB_N are always low; byte steering is done in the
  dcache lanes.

| | Per beat | Per line | Bandwidth |
|---|---|---|---|
| sram_ctl, 50 MHz, WAIT_CYCLES = 2 | 4 cycles (80 ns) | ~35 cycles (~0.7 µs) | ~23 MB/s |
| What the chip itself can do | 10 ns | ~80 ns | ~200 MB/s |

The margin was chosen for first bring-up. `WAIT_CYCLES = 1` should still be
inside the chip's spec but hasn't been tried on the board yet.

### 3.7 M4K budget

| | Data | Tag + valid | Dirty | Total |
|---|---|---|---|---|
| dcache, 16 KB | 32 | 2 | 1 | 35 |
| icache, 8 KB | 16 | 1 | — | 17 |
| **Total** | | | | **52 / 52** |

Every M4K is used, so SignalTap (which needs M4Ks for its sample buffer) only
fits if a cache is shrunk first.

### 3.8 Miss costs

| Event | Cycles |
|---|---|
| dcache miss, clean victim | ~42 |
| dcache miss, dirty victim (write-back, then fill) | ~85 |
| icache miss | ~45 |

Misses are served at the full 50 MHz in every speed mode, so the same miss
costs fewer CPU cycles at the 25 MHz setting.

---

## 4. Board wrapper (`quartus/soc_top.v`)

### 4.1 Clocking and reset

| SW9:8 | CPU speed (latched at reset) |
|---|---|
| 11 | 50 MHz |
| 10 | 25 MHz |
| 01 | ~1.5 Hz |
| 00 | one cycle per KEY1 press |

- **One clock:** everything runs on CLOCK_50; the speed setting is a clock enable.
- **Reset:** KEY0 resets the CPU (there's also a power-on reset). After every
  reset the dcache sweep runs, then the program starts. The counters start
  when the memory is ready, so the sweep is never counted.

### 4.2 Halt

Retiring `j .` halts the program. The counters freeze immediately and the
CPU's clock enable drops two cycles later, so we can examine final values.

### 4.3 Display and readout words

SW3:0 picks one of 16 readout words for HEX3..0 and the LEDs; SW4 = 1 shows the
upper half. The same word numbers are the JTAG selectors, and the same numbers
appear in `bench.py`'s output.

| SW3:0 | Word | SW3:0 | Word |
|---|---|---|---|
| 0000 | cycles | 1000 | status |
| 0001 | retired | 1001 | retiring pc |
| 0010 | stalls (load-use) | 1010 | retiring instr |
| 0011 | flushes (mispredict / jalr) | 1011 | pc in ID |
| 0100 | x28 | 1100 | write-back data |
| 0101 | x29 | 1101 | dcache misses |
| 0110 | x30 | 1110 | dcache write-backs |
| 0111 | x31 | 1111 | icache misses |

The status word is `{0xA5, version 3, 8'h00, low byte}`, where the low byte
carries the 1-bit debug outputs (one green LED each when word 8 is shown):

| Bit | 0 | 2:1 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| | halted | speed | mem_ready | reg_write | retire_valid | stall | redirect |

### 4.4 JTAG readout

An In-System Sources and Probes instance ("BNCH") returns any readout word
over the USB-Blaster. It uses no M4Ks. `quartus/read_results.tcl` reads all
16 words, after the program halts so the values are stable.

---

## 5. Verification

### 5.1 Method

Every program runs on the RTL and on `verif/tools/rvsim.py`, an independent
RV32I reference model, and the runner compares:

1. the retire trace, instr by instr (pc, instr, rd, write data)
2. the final regfile and every nonzero data mem word (read through dirty
   dcache lines)
3. optional hand-written `# EXPECT` values in the test source
4. optional exact stall and flush counts, so a pipeline that stalls when it
   doesn't need to still fails

The SRAM model (`verif/tb/sram_model.v`) checks the chip's timing rules
(address and data setup and hold around WE_N, access time, bus contention)
on every simulation.

### 5.2 Running the tests

```
python verif/run_unit_tests.py
python verif/run_directed_tests.py                      # test_lists/default.txt
python verif/run_directed_tests.py --test t2_load_use.S
python verif/run_directed_tests.py --list verif/test_lists/program.txt
python verif/run_randomized_tests.py --count 300
python verif/run_randomized_tests.py --seed 17          # one program, full output
```

Both pipeline runners take `--clken full|half|rand` (with `--seed`) and
`--icache warm|cold`:

| Option | What it exercises |
|---|---|
| `--clken half` / `rand` | clk_en low every other cycle, or randomly; results must not change |
| `--icache cold` | the program starts in SRAM, not the icache, so every line comes in through an icache miss and competes with dcache misses for the arbiter |

Results and stall/flush counts must be identical in every `--clken` mode. Data
misses freeze the whole pipeline, so they don't change those counts either.
`--icache cold` can legitimately move stalls and flushes, so exact counts are
only checked warm. Run the combinations (for example `--icache cold --clken
half`) after any change to the caches.

### 5.3 Test sources

| Kind | What |
|---|---|
| Directed (`verif/test_scripts/`) | Forwarding, load-use stalls at each distance, stores, control flow, memory ops, branch prediction (exact flush counts), dcache evictions (`dc_evict.S`) |
| Random (`verif/tools/randgen.py`) | Biased to short RAW distances, x0, loads and stores that collide, loops, branches and jumps. Half the loads and stores go through x13, a base that jumps between regions 16 KB apart, so they fight over the same dcache lines and force dirty evictions. |
| Unit (`run_unit_tests.py`) | Branch predictor, sram_ctl, the SRAM memory test, the retired imem/dmem, and `tb_dcache`: 50,000 random accesses against a reference memory, plus a run that checks the reset sweep zeroes an SRAM that powers up as X |

Directed test annotations, checked against both the model and the RTL:

```
# EXPECT x5 = 13
# EXPECT m2 = 0x55        data mem word 2
# EXPECT stalls = 1
# EXPECT flushes = 2
```

---

## 6. Running on the board

From `quartus/` (Quartus is at `D:\altera\13.0sp1\quartus\bin64`, not on PATH):

```
python bench.py programs/bench_sort.S                 # assemble, predict, install as program.hex
quartus_sh --flow compile soc_top
quartus_pgm -c "USB-Blaster [USB-0]" -m jtag -o "p;output_files/soc_top.sof"
# set SW9:8 = 11, press KEY0
python bench.py programs/bench_sort.S --no-install --board
```

`bench.py` runs `tb_bench.v`, a simulation twin of `soc_top` with the same
counters, halt, freeze and readout mux, and prints all 16 words with the
SW3:0 setting for each. With `--board` it reads the board over JTAG,
simulates at the board's own speed setting, and marks any word that differs.

A JTAG programming is lost at power-off. To keep a design, write
`output_files/soc_top.pof` into the EPCS4 flash with the RUN/PROG switch on
PROG.

---

## 7. Results

**bench_sort** (insertion sort of 64 words, 71 instrs), predicted by
`bench.py`:

| | 50 MHz setting | 25 MHz setting |
|---|---|---|
| cycles | 28,564 | 28,228 |
| retired | 25,276 | 25,276 |
| CPI | 1.130 | 1.117 |
| load-use stalls | 1,044 | 1,044 |
| flushes | 1,568 | 1,568 |
| dcache misses / write-backs | 16 / 0 | 16 / 0 |
| icache misses | 0 | 0 |
| x28 (checksum) | 396622 | 396622 |

The cycle count adds up: 25,276 retired + 1,044 stalls + 1,568 flushes +
16 misses x 42 = 28,560, plus a few cycles of pipeline fill. The 16 misses
are compulsory: one per 16-byte line of the 64-word array.

Before the caches, bench_sort ran on the board and matched the prediction on
every counter. The cache build has been checked in simulation and timing; it
still needs its first `bench.py --board` comparison.

**Timing:** Fmax ~52–54 MHz depending on placement, about +1 ns setup slack at
50 MHz. The crit path is load data out of the dcache in WB -> forwarding into
EX -> branch compare -> `next_pc` -> icache address. Two changes got it under
20 ns after the caches went in:
- the `next_pc` split described in section 2.2
- a dedicated JALR adder, so the target doesn't wait on the ALU's shifter and
  result mux

---

## 8. Toolchain

| Purpose | Tool |
|---|---|
| RTL simulation | Icarus Verilog (`iverilog -g2005`, `vvp`) |
| Assembling programs | xPack RISC-V GCC `riscv-none-elf-gcc` / `objcopy` (`-march=rv32i -mabi=ilp32`, linked at 0) |
| Reference model, runners | Python 3 |
| Synthesis, fit, timing, programming, JTAG | Quartus II 13.0sp1 Web Edition (the last version that supports Cyclone II) |

`verif/tools/harness.py` has the project's absolute path in `PROJECT`; edit
that one line if the folder moves.

---

## 9. Known limitations and next steps

- **No loader yet.** Programs reach the CPU through the icache's bitstream
  preload, so they're limited to 8 KB and changing programs means a
  recompile. The SRAM's instr mem is never loaded on the board, so icache
  misses only happen in simulation. Next: a loader (UART or Virtual JTAG)
  that writes the SRAM, then a shared address map so code and data can use
  all 512 KB.
- **Harvard split.** Each side gets 256 KB and addresses wrap past that.
  Moving to one shared address space makes `REGION` 19 for both caches and
  adds one tag bit each, with no change in M4K count.
- **No CSRs, traps, interrupts or MMU.**
- **Thin timing margin** (~1 ns). Registering the load data in MEM would
  remove the whole group of paths that start at the dcache output, and should
  also allow ~65–70 MHz with a PLL.
- **Miss handling could be faster:** `WAIT_CYCLES = 1` (re-test on the board),
  a write-back buffer so a dirty miss doesn't wait for the write-back, reading
  the dirty bit early with a bypass, merging S_TAG into the last S_FILLWR
  cycle, or a mixed-width port B so a line goes in with one access.
