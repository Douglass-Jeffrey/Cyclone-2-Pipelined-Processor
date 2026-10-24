// =============================================================================
// sram_test_top -- board-level bring-up of the DE1's 512 KB SRAM (EP2C20)
//
// Runs sram_memtest over the whole chip forever, at 50 MHz, and shows the
// result.  A separate project from the CPU (quartus/sram_test/), so the SRAM's
// pins, bus and timing are proven on hardware before a CPU depends on them.
//
//   LEDG[7]   PASS: at least one full round done and no wrong word ever
//   LEDR[9]   FAIL: some word read back wrong
//   LEDG[0]   heartbeat (~1.5 Hz)         LEDG[2:1]  current phase
//   LEDR[7:0] error count, saturating at 255
//   HEX3..0   SW[0]=0: rounds completed   SW[0]=1: first wrong byte address
//   KEY[0]    restart the test
//
// JTAG: In-System Sources and Probes instance "SRMT"; read_sram_test.tcl reads it.
// =============================================================================
module sram_test_top (
    input  wire        CLOCK_50,
    input  wire [0:0]  KEY,
    input  wire [0:0]  SW,
    output wire [9:0]  LEDR,
    output wire [7:0]  LEDG,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,

    output wire [17:0] SRAM_ADDR,
    inout  wire [15:0] SRAM_DQ,
    output wire        SRAM_CE_N,
    output wire        SRAM_OE_N,
    output wire        SRAM_WE_N,
    output wire        SRAM_UB_N,
    output wire        SRAM_LB_N
);
    localparam ADDR_BITS = 19;          // 512 KB

    // power-on reset (~21 ms), then KEY0 restarts the test
    reg [19:0] por_cnt = 20'd0;
    reg [1:0]  key_s   = 2'b11;
    reg        rst     = 1'b1;
    always @(posedge CLOCK_50) begin
        if (por_cnt != 20'hFFFFF) por_cnt <= por_cnt + 20'd1;
        key_s <= {key_s[0], KEY[0]};
        rst   <= (por_cnt != 20'hFFFFF) || !key_s[1];
    end

    wire [31:0] rounds, errors, first_addr;
    wire [15:0] first_expected, first_got;
    wire [1:0]  phase;

    sram_memtest #(.ADDR_BITS(ADDR_BITS)) u_test (
        .clk            (CLOCK_50),
        .rst            (rst),
        .rounds         (rounds),
        .errors         (errors),
        .first_addr     (first_addr),
        .first_expected (first_expected),
        .first_got      (first_got),
        .phase          (phase),
        .SRAM_ADDR      (SRAM_ADDR),
        .SRAM_DQ        (SRAM_DQ),
        .SRAM_CE_N      (SRAM_CE_N),
        .SRAM_OE_N      (SRAM_OE_N),
        .SRAM_WE_N      (SRAM_WE_N),
        .SRAM_UB_N      (SRAM_UB_N),
        .SRAM_LB_N      (SRAM_LB_N)
    );

    wire pass = (rounds != 32'd0) && (errors == 32'd0);
    wire fail = (errors != 32'd0);

    reg [24:0] beat_cnt = 25'd0;
    always @(posedge CLOCK_50) beat_cnt <= beat_cnt + 25'd1;

    assign LEDG = {pass, 4'd0, phase, beat_cnt[24]};
    assign LEDR = {fail, 1'b0, (errors > 32'd255) ? 8'hFF : errors[7:0]};

    wire [15:0] hex_val = SW[0] ? first_addr[15:0] : rounds[15:0];
    assign HEX0 = seg7(hex_val[3:0]);
    assign HEX1 = seg7(hex_val[7:4]);
    assign HEX2 = seg7(hex_val[11:8]);
    assign HEX3 = seg7(hex_val[15:12]);

    // ---- JTAG readout: 3-bit selector in, selected word out ----------------
    // 0x53 ('S') in the status word tells the script it found this design,
    // not the CPU (whose BNCH status reads 0xA5 0x01).
    wire [2:0] probe_sel;
    reg  [31:0] probe_word;
    always @(*) begin
        case (probe_sel)
            3'd0:    probe_word = {8'hA5, 8'h53, 12'd0, phase, fail, pass};
            3'd1:    probe_word = rounds;
            3'd2:    probe_word = errors;
            3'd3:    probe_word = first_addr;
            3'd4:    probe_word = {first_expected, first_got};
            3'd5:    probe_word = 32'd1 << ADDR_BITS;   // bytes under test
            default: probe_word = 32'd0;
        endcase
    end

`ifndef __ICARUS__
    altsource_probe #(
        .sld_auto_instance_index ("YES"),
        .sld_instance_index      (0),
        .instance_id             ("SRMT"),
        .probe_width             (32),
        .source_width            (3),
        .source_initial_value    ("0"),
        .enable_metastability    ("NO"),
        .lpm_type                ("altsource_probe")
    ) u_isp (
        .probe      (probe_word),
        .source     (probe_sel),
        .source_clk (CLOCK_50),
        .source_ena (1'b1)
    );
`else
    assign probe_sel = 3'd0;
`endif

    // 7-segment decoder, active-low segments (same as soc_top.v)
    function [6:0] seg7;
        input [3:0] n;
        reg [6:0] p;   // active-high, bit0=a .. bit6=g
        begin
            case (n)
                4'h0: p = 7'h3F;
                4'h1: p = 7'h06;
                4'h2: p = 7'h5B;
                4'h3: p = 7'h4F;
                4'h4: p = 7'h66;
                4'h5: p = 7'h6D;
                4'h6: p = 7'h7D;
                4'h7: p = 7'h07;
                4'h8: p = 7'h7F;
                4'h9: p = 7'h6F;
                4'hA: p = 7'h77;
                4'hB: p = 7'h7C;
                4'hC: p = 7'h39;
                4'hD: p = 7'h5E;
                4'hE: p = 7'h79;
                4'hF: p = 7'h71;
                default: p = 7'h00;
            endcase
            seg7 = ~p;    // active-low output
        end
    endfunction
endmodule
