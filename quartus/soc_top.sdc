# soc_top.sdc   Timing constraints
#
# The board clock is the only real clock.
# Quartus will promote it onto a global clock network,
# which is what keeps hold times safe
# across the ~40 pipeline registers it drives.

# 50 MHz board oscillator
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

# cpu_clk.  Constrained at the FASTEST rate the switches can select: /2, a
# 40 ns period (25 MHz).  Every slower mode is then covered with enormous
# margin, and this is the setting that actually has to close.
#
# Takeaways from struggles with timing
#  - TimeQuest rejects any clock whose period exceeds 2,147,483.647 ns.  The
#    obvious "-divide_by 524288" for the ~95 Hz tick is a 10.5 ms period, so it
#    is silently DISCARDED and the whole CPU goes unconstrained -- including
#    HOLD analysis, which is frequency-independent and the only thing that can
#    actually break a slowly-clocked design.
#  - Constraining only the slow rate would have hidden the fact that the core
#    barely closes at 25 MHz.
create_generated_clock -name cpu_clk -source [get_ports CLOCK_50] \
    -divide_by 2 [get_registers {cpu_clk_r}]
derive_clock_uncertainty

# dont care about human response time i/o
set_false_path -from [get_ports {SW[*] KEY[*]}] -to [all_registers]
set_false_path -from * -to [get_ports {LEDR[*] LEDG[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*]}]

# The CPU runs entirely on cpu_clk; the divider and debouncer run entirely on
# CLOCK_50.  The only crossings are rst and the tick pulse, both of which are
# stable for millions of CLOCK_50 cycles around a CPU edge.
set_clock_groups -asynchronous -group {CLOCK_50} -group {cpu_clk}
