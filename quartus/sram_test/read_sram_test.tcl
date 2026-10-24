# =============================================================================
# read_sram_test.tcl -- read the SRAM bring-up result off the board over JTAG.
#
#   quartus_stp -t read_sram_test.tcl
#
# Talks to the altsource_probe instance ("SRMT") in sram_test_top.v: writes a
# 3-bit selector through `source`, reads the selected word back through
# `probe`.  The test runs forever, so the counts are a live snapshot; run it
# again a few seconds later and `rounds` should have grown.
# =============================================================================

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

if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} err]} {
    puts "ERROR: could not open the In-System Sources and Probes instance:"
    puts "       $err"
    puts "       Is the board programmed with sram_test.sof?"
    exit 1
}

set status [read_word 0]
if {(($status >> 16) & 0xFFFF) != 0xA553} {
    puts "ERROR: status [format 0x%08X $status] is not the SRAM test's signature (0xA553....)."
    puts "       The board is probably running a different design, e.g. the CPU."
    end_insystem_source_probe
    exit 1
}
set rounds  [read_word 1]
set errors  [read_word 2]
set faddr   [read_word 3]
set fdata   [read_word 4]
set bytes   [read_word 5]
end_insystem_source_probe

set pass  [expr {$status & 1}]
set phase [expr {($status >> 2) & 3}]
set names [list "write" "verify" "write inverted" "verify inverted"]

puts ""
puts "memory   : [expr {$bytes / 1024}] KB under test"
puts "rounds   : $rounds complete (each: write, verify, write inverted, verify inverted)"
puts "phase    : [lindex $names $phase]"
puts "errors   : $errors wrong 16-bit word(s)"
if {$errors == 0} {
    if {$pass} {
        puts "result   : PASS"
    } else {
        puts "result   : no errors yet, first round still running"
    }
} else {
    puts "result   : FAIL"
    puts [format "first    : byte 0x%05X  expected 0x%04X  got 0x%04X" \
              $faddr [expr {($fdata >> 16) & 0xFFFF}] [expr {$fdata & 0xFFFF}]]
}
