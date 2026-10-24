# =============================================================================
# read_results.tcl -- pull benchmark results off the board over JTAG.
#
#   quartus_stp -t read_results.tcl
#
# Talks to the altsource_probe instance ("BNCH") in soc_top.v through the same
# USB-Blaster cable used to program the board: writes a 4-bit selector through
# `source`, reads the selected 32-bit word back through `probe`.  No UART, no
# extra pins.
#
# Run it AFTER the program has halted (status bit 0 set, or just look at the
# board).  While the CPU is running the counters change every cycle and a
# 32-bit JTAG read is not atomic, so a value could tear.  Once halted, the
# wrapper freezes the counters and stops cpu_clk, so every read is stable.
# =============================================================================

# Select one of the wrapper's readout words (see readout() in soc_top.v) and
# read it back.  Both commands default to BINARY strings, so use hex explicitly.
proc read_word {sel} {
    write_source_data -instance_index 0 -value [format %X $sel] -value_in_hex
    # one throwaway read lets the selector propagate into the readout mux
    read_probe_data -instance_index 0 -value_in_hex
    scan [read_probe_data -instance_index 0 -value_in_hex] %x v
    return $v
}

# ---- find the cable, the FPGA on it, and open the probe ---------------------
set hw_names [get_hardware_names]
if {[llength $hw_names] == 0} {
    puts "ERROR: no programming hardware found. Is the USB-Blaster plugged in?"
    exit 1
}
set hw  [lindex $hw_names 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
puts "hardware : $hw"
puts "device   : $dev"

if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} err]} {
    puts "ERROR: could not open the In-System Sources and Probes instance:"
    puts "       $err"
    puts "       Is the board programmed with this soc_top.sof?"
    exit 1
}

# ---- sanity check -----------------------------------------------------------
set status [read_word 8]
set magic  [expr {($status >> 24) & 0xFF}]
if {$magic != 0xA5} {
    puts "ERROR: status magic is [format 0x%02X $magic], expected 0xA5."
    puts "       The board is probably running an older .sof."
    end_insystem_source_probe
    exit 1
}

set halted  [expr {$status & 1}]
set speed   [expr {($status >> 1) & 3}]
# SW9:8 encoding latched by soc_top.v at reset (matches bench.py's RATES)
set rates   [list "single step" "~1.5 Hz" "25 MHz" "50 MHz"]
set mhz     [list 0.0 [expr {50.0 / pow(2, 25)}] 25.0 50.0]

# ---- collect: every readout word ---------------------------------------------
# names must match soc_top.v's readout() and bench.py's WORDS
set names [list "cycles" "retired" "stalls" "flushes" "x28" "x29" "x30" "x31" \
                "status" "retiring pc" "retiring instr" "pc in ID" "write-back data" \
                "D-cache misses" "D write-backs" "I-cache misses"]
set w {}
for {set i 0} {$i < 16} {incr i} { lappend w [read_word $i] }

end_insystem_source_probe

set cyc     [lindex $w 0]
set retired [lindex $w 1]
set stalls  [lindex $w 2]
set flushes [lindex $w 3]
set r0      [lindex $w 4]
set r1      [lindex $w 5]
set r2      [lindex $w 6]
set r3      [lindex $w 7]
set status  [lindex $w 8]
set pc      [lindex $w 9]
set instr   [lindex $w 10]
set dmiss   [lindex $w 13]
set dwb     [lindex $w 14]
set imiss   [lindex $w 15]

# ---- report -----------------------------------------------------------------
puts ""
puts "clock    : [lindex $rates $speed]"
if {$halted} {
    puts "state    : HALTED (counters frozen, values below are final)"
} else {
    puts "state    : STILL RUNNING -- values are a live snapshot and may be torn."
    puts "           Let the program reach its `j .` halt, then re-run."
}
puts ""
puts "cycles   : $cyc"
puts "retired  : $retired"
puts "stalls   : $stalls   (load-use interlock)"
puts "flushes  : $flushes   (branch mispredict / jalr)"
puts "D-cache  : $dmiss misses, $dwb dirty write-backs"
puts "I-cache  : $imiss misses"
if {$retired > 0} {
    puts "CPI      : [format %.4f [expr {double($cyc) / $retired}]]"
    set f [lindex $mhz $speed]
    if {$f > 1.0} {
        puts "runtime  : [format %.3f [expr {$cyc / ($f * 1000.0)}]] ms at [lindex $rates $speed]"
        puts "MIPS     : [format %.2f [expr {$retired * $f / double($cyc)}]]"
    }
}
puts ""
puts "results  : x28 = $r0   ([format 0x%08X $r0])"
puts "           x29 = $r1   ([format 0x%08X $r1])"
puts "           x30 = $r2   ([format 0x%08X $r2])"
puts "           x31 = $r3   ([format 0x%08X $r3])"
puts ""
puts "halt pc  : [format 0x%08X $pc]  instr [format 0x%08X $instr]"

# ---- every word, in the same order and names as bench.py --------------------
# (bench.py --board reads the "word" lines below, so keep their format)
puts ""
puts "all readout words (word number = JTAG selector):"
for {set i 0} {$i < 16} {incr i} {
    set v [lindex $w $i]
    puts [format "  word %2d  %-16s %12u  0x%08X" $i [lindex $names $i] $v $v]
}
puts [format "  status bits: halted=%d speed=%d%d mem_ready=%d reg_write=%d retire_valid=%d stall=%d redirect=%d" \
          [expr {$status & 1}] [expr {($status >> 2) & 1}] [expr {($status >> 1) & 1}] \
          [expr {($status >> 3) & 1}] [expr {($status >> 4) & 1}] [expr {($status >> 5) & 1}] \
          [expr {($status >> 6) & 1}] [expr {($status >> 7) & 1}]]
