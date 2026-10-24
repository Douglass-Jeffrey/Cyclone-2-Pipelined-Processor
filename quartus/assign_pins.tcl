# =============================================================================
# assign_pins.tcl  -assign pins through tcl console since quartus is erasing
# them from qsf file
#
# sometimes need to run this script after compilation from this folder
# Board  : Altera Cyclone II FPGA Starter Development Board
# Device : EP2C20F484C7N
# =============================================================================

# clk
set_location_assignment PIN_L1  -to CLOCK_50

# switches
set_location_assignment PIN_L22 -to SW[0]
set_location_assignment PIN_L21 -to SW[1]
set_location_assignment PIN_M22 -to SW[2]
set_location_assignment PIN_V12 -to SW[3]
set_location_assignment PIN_W12 -to SW[4]
set_location_assignment PIN_U12 -to SW[5]
set_location_assignment PIN_U11 -to SW[6]
set_location_assignment PIN_M2  -to SW[7]
set_location_assignment PIN_M1  -to SW[8]
set_location_assignment PIN_L2  -to SW[9]

# buttons
set_location_assignment PIN_R22 -to KEY[0]
set_location_assignment PIN_R21 -to KEY[1]
set_location_assignment PIN_T22 -to KEY[2]
set_location_assignment PIN_T21 -to KEY[3]

# red led
set_location_assignment PIN_R20 -to LEDR[0]
set_location_assignment PIN_R19 -to LEDR[1]
set_location_assignment PIN_U19 -to LEDR[2]
set_location_assignment PIN_Y19 -to LEDR[3]
set_location_assignment PIN_T18 -to LEDR[4]
set_location_assignment PIN_V19 -to LEDR[5]
set_location_assignment PIN_Y18 -to LEDR[6]
set_location_assignment PIN_U18 -to LEDR[7]
set_location_assignment PIN_R18 -to LEDR[8]
set_location_assignment PIN_R17 -to LEDR[9]

# green led
set_location_assignment PIN_U22 -to LEDG[0]
set_location_assignment PIN_U21 -to LEDG[1]
set_location_assignment PIN_V22 -to LEDG[2]
set_location_assignment PIN_V21 -to LEDG[3]
set_location_assignment PIN_W22 -to LEDG[4]
set_location_assignment PIN_W21 -to LEDG[5]
set_location_assignment PIN_Y22 -to LEDG[6]
set_location_assignment PIN_Y21 -to LEDG[7]

# 7seg display
set_location_assignment PIN_J2 -to HEX0[0]
set_location_assignment PIN_J1 -to HEX0[1]
set_location_assignment PIN_H2 -to HEX0[2]
set_location_assignment PIN_H1 -to HEX0[3]
set_location_assignment PIN_F2 -to HEX0[4]
set_location_assignment PIN_F1 -to HEX0[5]
set_location_assignment PIN_E2 -to HEX0[6]
set_location_assignment PIN_E1 -to HEX1[0]
set_location_assignment PIN_H6 -to HEX1[1]
set_location_assignment PIN_H5 -to HEX1[2]
set_location_assignment PIN_H4 -to HEX1[3]
set_location_assignment PIN_G3 -to HEX1[4]
set_location_assignment PIN_D2 -to HEX1[5]
set_location_assignment PIN_D1 -to HEX1[6]
set_location_assignment PIN_G5 -to HEX2[0]
set_location_assignment PIN_G6 -to HEX2[1]
set_location_assignment PIN_C2 -to HEX2[2]
set_location_assignment PIN_C1 -to HEX2[3]
set_location_assignment PIN_E3 -to HEX2[4]
set_location_assignment PIN_E4 -to HEX2[5]
set_location_assignment PIN_D3 -to HEX2[6]
set_location_assignment PIN_F4 -to HEX3[0]
set_location_assignment PIN_D5 -to HEX3[1]
set_location_assignment PIN_D6 -to HEX3[2]
set_location_assignment PIN_J4 -to HEX3[3]
set_location_assignment PIN_L8 -to HEX3[4]
set_location_assignment PIN_F3 -to HEX3[5]
set_location_assignment PIN_D4 -to HEX3[6]

# SRAM (from Terasic's DE1_pin_assignments.csv), plus I/O-cell registers
set_location_assignment PIN_AA3 -to SRAM_ADDR[0]
set_location_assignment PIN_AB3 -to SRAM_ADDR[1]
set_location_assignment PIN_AA4 -to SRAM_ADDR[2]
set_location_assignment PIN_AB4 -to SRAM_ADDR[3]
set_location_assignment PIN_AA5 -to SRAM_ADDR[4]
set_location_assignment PIN_AB10 -to SRAM_ADDR[5]
set_location_assignment PIN_AA11 -to SRAM_ADDR[6]
set_location_assignment PIN_AB11 -to SRAM_ADDR[7]
set_location_assignment PIN_V11 -to SRAM_ADDR[8]
set_location_assignment PIN_W11 -to SRAM_ADDR[9]
set_location_assignment PIN_R11 -to SRAM_ADDR[10]
set_location_assignment PIN_T11 -to SRAM_ADDR[11]
set_location_assignment PIN_Y10 -to SRAM_ADDR[12]
set_location_assignment PIN_U10 -to SRAM_ADDR[13]
set_location_assignment PIN_R10 -to SRAM_ADDR[14]
set_location_assignment PIN_T7 -to SRAM_ADDR[15]
set_location_assignment PIN_Y6 -to SRAM_ADDR[16]
set_location_assignment PIN_Y5 -to SRAM_ADDR[17]
set_location_assignment PIN_AA6 -to SRAM_DQ[0]
set_location_assignment PIN_AB6 -to SRAM_DQ[1]
set_location_assignment PIN_AA7 -to SRAM_DQ[2]
set_location_assignment PIN_AB7 -to SRAM_DQ[3]
set_location_assignment PIN_AA8 -to SRAM_DQ[4]
set_location_assignment PIN_AB8 -to SRAM_DQ[5]
set_location_assignment PIN_AA9 -to SRAM_DQ[6]
set_location_assignment PIN_AB9 -to SRAM_DQ[7]
set_location_assignment PIN_Y9 -to SRAM_DQ[8]
set_location_assignment PIN_W9 -to SRAM_DQ[9]
set_location_assignment PIN_V9 -to SRAM_DQ[10]
set_location_assignment PIN_U9 -to SRAM_DQ[11]
set_location_assignment PIN_R9 -to SRAM_DQ[12]
set_location_assignment PIN_W8 -to SRAM_DQ[13]
set_location_assignment PIN_V8 -to SRAM_DQ[14]
set_location_assignment PIN_U8 -to SRAM_DQ[15]
set_location_assignment PIN_AB5 -to SRAM_CE_N
set_location_assignment PIN_T8 -to SRAM_OE_N
set_location_assignment PIN_AA10 -to SRAM_WE_N
set_location_assignment PIN_W7 -to SRAM_UB_N
set_location_assignment PIN_Y7 -to SRAM_LB_N
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to SRAM_ADDR[*]
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to SRAM_CE_N
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to SRAM_OE_N
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to SRAM_WE_N
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to SRAM_DQ[*]
set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to SRAM_DQ[*]
set_instance_assignment -name FAST_INPUT_REGISTER ON -to SRAM_DQ[*]

# I/O standard and unused pins
set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"
set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"

# export
export_assignments
puts "Pin assignments applied and exported to soc_top.qsf"
