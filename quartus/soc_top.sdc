# soc_top.sdc   Timing constraints
#
# The board clock is the only real clock.
# Quartus will promote it onto a global clock network,
# which is what keeps hold times safe
# across the ~40 pipeline registers it drives.

# 50 MHz board oscillator
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

# cpu_clk is CLOCK_50 through a clock mux, so TimeQuest propagates CLOCK_50 to
# the CPU and checks it at 50 MHz, the fastest mode.
#
# Takeaways from struggles with timing
#  - TimeQuest rejects any clock whose period exceeds 2,147,483.647 ns.  The
#    obvious "-divide_by 524288" for the ~95 Hz tick is a 10.5 ms period, so it
#    is silently DISCARDED and the whole CPU goes unconstrained -- including
#    HOLD analysis, which is frequency-independent and the only thing that can
#    actually break a slowly-clocked design.
#  - Constraining only the slow rate would have hidden the fact that the core
#    barely closes at 25 MHz.
derive_clock_uncertainty

# dont care about human response time i/o
set_false_path -from [get_ports {SW[*] KEY[*]}] -to [all_registers]
set_false_path -from * -to [get_ports {LEDR[*] LEDG[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*]}]

# 25 MHz sign-off: uncomment to give paths out of the CPU two CLOCK_50 periods (40 ns)
# set_multicycle_path -setup -end 2 -from [get_registers {*u_cpu|*}]
# set_multicycle_path -hold  -end 1 -from [get_registers {*u_cpu|*}]
