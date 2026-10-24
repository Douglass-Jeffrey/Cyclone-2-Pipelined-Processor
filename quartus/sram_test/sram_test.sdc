# sram_test.sdc   Timing constraints for the SRAM bring-up design

# 50 MHz board oscillator
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty

# dont care about human response time i/o
set_false_path -from [get_ports {SW[*] KEY[*]}] -to [all_registers]
set_false_path -from * -to [get_ports {LEDR[*] LEDG[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*]}]

# The SRAM is asynchronous: sram_ctl times it with whole clock cycles (address
# and data settle a cycle before WE_N falls and hold a cycle after it rises;
# reads sample 3 cycles after the address), and every pin comes straight from
# an I/O-cell register.  There is no single-cycle path to check.
set_false_path -to   [get_ports {SRAM_*}]
set_false_path -from [get_ports {SRAM_DQ[*]}]
