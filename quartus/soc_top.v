// =============================================================================
// soc_top.v   Board wrapper for the 5-stage pipelined RV32I core
//
// Target : Altera Cyclone II FPGA Starter Development Board (EP2C20F484C7N)
//
// Two jobs:
//   1. OBSERVE.  At 3-95 Hz a human can watch the pipeline advance one cycle
//      at a time on the LEDs and 7-segment displays.
//   2. BENCHMARK.  At 12.5/25 MHz the core runs real programs at speed, stops
//      itself when the program halts, and hands the results back over JTAG so
//      a script can collect them.  No extra board pins are used.
//
// Clocking
//   CLOCK_50 is the only oscillator.  cpu_clk is derived from it and is the
//   clock for the CPU and all performance counters.
//     slow  : one 20 ns pulse every 2^24 CLOCK_50 cycles  (~3 Hz)
//     med   : one 20 ns pulse every 2^19 CLOCK_50 cycles  (~95 Hz)
//     fast  : a real 50% duty square wave at 25 MHz (/2) or 12.5 MHz (/4)
//   The core's measured Fmax is 25.42 MHz, so /2 is the fastest legal rate and
//   it has very little margin -- /4 is the safe fallback if the board misbehaves.
//   cpu_clk is always a registered CLOCK_50-aligned signal, so switching modes
//   or gating it on halt can never produce a runt pulse.
//
// Reset
//   The core resets SYNCHRONOUSLY, so it only notices reset on a rising cpu_clk
//   edge.  At 3 Hz those are 335 ms apart while a 2^16-cycle power-on pulse
//   lasts 1.3 ms, so a plain POR would be missed ~99.6% of the time and the
//   pipeline would come up with random valid bits.  An async-assert /
//   sync-deassert synchronizer clocked by cpu_clk fixes that.
// =============================================================================
module soc_top (
    input  wire        CLOCK_50,   // 50 MHz oscillator          (PIN_L1)
    input  wire [3:0]  KEY,        // push buttons, active-low
    input  wire [9:0]  SW,         // switches, active-high
    output wire [9:0]  LEDR,       // red leds
    output wire [7:0]  LEDG,       // green leds
    output wire [6:0]  HEX0,       // 7-segm displays, active-LOW segments
    output wire [6:0]  HEX1,       // segment order: bit0=a, bit1=b, ... bit6=g
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3
);

    // ---- power-on reset request -------------------------------------------
    reg [15:0] por_cnt = 16'd0;
    reg        por     = 1'b1;
    always @(posedge CLOCK_50) begin
        if (por_cnt != 16'hFFFF) begin
            por_cnt <= por_cnt + 16'd1;
            por     <= 1'b1;
        end else begin
            por     <= 1'b0;
        end
    end

    wire rst_request = por | ~KEY[0];

    // Select clock speed debug
    // Latched while reset is asserted, so the clock source never changes under
    // a running pipeline.  Set the switches, then press KEY0.
    //   speed[1] = fast,  speed[0] = the rate within the chosen family
    //     2'b00 ~3 Hz      2'b01 ~95 Hz      2'b10 25 MHz      2'b11 12.5 MHz
    reg [1:0] speed = 2'b00;
    always @(posedge CLOCK_50)
        if (rst_request) speed <= SW[3] ? {1'b1, SW[2]} : {1'b0, SW[8]};

    // slow-tick divider
    reg [24:0] div = 25'd0;
    always @(posedge CLOCK_50) div <= div + 25'd1;

    wire slow_tick = (div[23:0] == 24'd0);
    wire med_tick  = (div[18:0] == 19'd0);
    wire run_tick  = speed[0] ? med_tick : slow_tick;

    // /4 needs a half-rate toggle enable; /2 toggles every CLOCK_50 edge
    reg div2 = 1'b0;
    always @(posedge CLOCK_50) div2 <= ~div2;

    // enable one tick per KEY[1] press debounced
    wire step_pulse;
    debounce_pulse #(.STABLE(16)) u_step (
        .clk   (CLOCK_50),
        .rst   (por),
        .btn_n (KEY[1]),
        .pulse (step_pulse)
    );

    wire cpu_clk;
    wire halted;

    // Freeze clock on program halt so we can examine final values.
    // halted crosses from cpu_clk into
    // CLOCK_50, so synchronise it; it only ever transitions once.
    reg halted_s0 = 1'b0, halted_s1 = 1'b0;
    always @(posedge CLOCK_50) begin
        halted_s0 <= halted;
        halted_s1 <= halted_s0;
    end

    wire advance = !SW[9]   ? step_pulse
                 : speed[1] ? (speed[0] ? (div2 ? ~cpu_clk : cpu_clk)  // /4
                                        : ~cpu_clk)                    // /2
                 :            run_tick;

    reg cpu_clk_r = 1'b0;
    always @(posedge CLOCK_50) cpu_clk_r <= advance & ~halted_s1;
    assign cpu_clk = cpu_clk_r;

    // async reset logic
    reg rst_n_sync = 1'b0;
    always @(posedge cpu_clk or posedge rst_request) begin
        if (rst_request) rst_n_sync <= 1'b0;
        else             rst_n_sync <= 1'b1;
    end
    wire rst = ~rst_n_sync;

    // instantiate the cpu
    wire [31:0] dbg_pc, dbg_instr, dbg_wb_data, dbg_if_pc;
    wire        dbg_reg_write, dbg_retire_valid, dbg_stall, dbg_redirect;

    pipelined_datapath #(
        .RESET_PC  (32'h0000_0000),
        .IMEM_INIT ("program.hex")
    ) u_cpu (
        .clk              (cpu_clk),
        .rst              (rst),
        .dbg_pc           (dbg_pc),
        .dbg_instr        (dbg_instr),
        .dbg_wb_data      (dbg_wb_data),
        .dbg_reg_write    (dbg_reg_write),
        .dbg_if_pc        (dbg_if_pc),
        .dbg_retire_valid (dbg_retire_valid),
        .dbg_stall        (dbg_stall),
        .dbg_redirect     (dbg_redirect)
    );

    // Detect halts
    // `j .` (jal x0, 0) encodes as 0x0000006F and is the idiom every test and
    // benchmark here ends with -- the same one the Python reference model uses
    // to stop.  Retiring it once means the program is done.
    localparam [31:0] HALT_INSTR = 32'h0000_006F;

    reg halted_r = 1'b0;
    always @(posedge cpu_clk or posedge rst) begin
        if (rst)                                                    halted_r <= 1'b0;
        else if (dbg_retire_valid && (dbg_instr == HALT_INSTR))     halted_r <= 1'b1;
    end
    assign halted = halted_r;

    // Debug counters
    // Frozen by `halted` so the final reading is stable for the probes.  The
    // halting `j .` itself is counted, which matches the reference model's
    // trace, so RTL and model instruction counts line up exactly.
    reg [31:0] cyc     = 32'd0;
    reg [31:0] retired = 32'd0;
    reg [31:0] stalls  = 32'd0;
    reg [31:0] flushes = 32'd0;
    always @(posedge cpu_clk or posedge rst) begin
        if (rst) begin
            cyc     <= 32'd0;
            retired <= 32'd0;
            stalls  <= 32'd0;
            flushes <= 32'd0;
        end else if (!halted_r) begin
            cyc <= cyc + 32'd1;
            if (dbg_retire_valid) retired <= retired + 32'd1;
            if (dbg_stall)        stalls  <= stalls  + 32'd1;
            if (dbg_redirect)     flushes <= flushes + 32'd1;
        end
    end

    // capture results
    wire [4:0] retire_rd = dbg_instr[11:7];
    wire       capture   = dbg_retire_valid && dbg_reg_write &&
                           (retire_rd[4:2] == 3'b111) && !halted_r;

    reg [31:0] result0 = 32'd0, result1 = 32'd0,
               result2 = 32'd0, result3 = 32'd0;
    always @(posedge cpu_clk or posedge rst) begin
        if (rst) begin
            result0 <= 32'd0; result1 <= 32'd0;
            result2 <= 32'd0; result3 <= 32'd0;
        end else if (capture) begin
            case (retire_rd[1:0])
                2'd0: result0 <= dbg_wb_data;   // x28 / t3
                2'd1: result1 <= dbg_wb_data;   // x29 / t4
                2'd2: result2 <= dbg_wb_data;   // x30 / t5
                2'd3: result3 <= dbg_wb_data;   // x31 / t6
            endcase
        end
    end

    // 0xA5 magic lets a host script confirm it is talking to this design;
    // bumping the version byte flags a stale .sof.
    wire [31:0] status = {8'hA5, 8'd1, 13'd0, speed, halted_r};

    // ---- readout mux -------------------------------------------------------
    // One mux feeds both the 7-segment display and the JTAG probe, so what a
    // script reads and what the board shows can never disagree.
    function [31:0] readout;
        input [3:0] sel;
        begin
            case (sel)
                4'd0:  readout = cyc;
                4'd1:  readout = retired;
                4'd2:  readout = stalls;
                4'd3:  readout = flushes;
                4'd4:  readout = result0;
                4'd5:  readout = result1;
                4'd6:  readout = result2;
                4'd7:  readout = result3;
                4'd8:  readout = status;
                4'd9:  readout = dbg_pc;
                4'd10: readout = dbg_instr;
                4'd11: readout = dbg_if_pc;
                4'd12: readout = dbg_wb_data;
                default: readout = 32'd0;
            endcase
        end
    endfunction

    // Board display: SW1 picks the bank, SW7:5 the entry within it.
    //   SW1=0  live pipeline state      SW1=1  benchmark counters and results
    // SW1=0 keeps the meanings the existing board notes document, so nothing
    // already written down about SW7:5 changes.
    reg [3:0] sel_r;
    always @(*) begin
        if (SW[1]) begin
            sel_r = {1'b0, SW[7:5]};          // 0 cyc 1 retired 2 stalls 3 flushes
                                              // 4..7 result0..3
        end else begin
            case (SW[7:5])
                3'd0: sel_r = 4'd9;           // retiring pc
                3'd1: sel_r = 4'd10;          // retiring instruction
                3'd2: sel_r = 4'd12;          // write-back data
                3'd3: sel_r = 4'd11;          // pc in ID (front end)
                3'd4: sel_r = 4'd0;           // cycles
                3'd5: sel_r = 4'd1;           // retired
                3'd6: sel_r = 4'd2;           // stalls
                default: sel_r = 4'd3;        // flushes
            endcase
        end
    end

    wire [31:0] disp_val = readout(sel_r);

    // leds, if sw4 high show upper 18 bits of disp_val, else lower 18 bits
    wire [17:0] window = SW[4] ? disp_val[31:14] : disp_val[17:0];
    assign LEDG = window[7:0];
    assign LEDR = window[17:8];

    // 7-seg, same as above
    wire [15:0] hex_val = SW[4] ? disp_val[31:16] : disp_val[15:0];
    assign HEX0 = seg7(hex_val[3:0]);
    assign HEX1 = seg7(hex_val[7:4]);
    assign HEX2 = seg7(hex_val[11:8]);
    assign HEX3 = seg7(hex_val[15:12]);

    // JTAG readout disabled for now
    // // ---- JTAG readout ------------------------------------------------------
    // // In-System Sources and Probes: the host writes a 4-bit selector through
    // // `source` and reads the selected 32-bit word back through `probe`, over
    // // the same USB-Blaster cable used to program the board.  No pins, no UART.
    // // Read AFTER halt: the counters are frozen then, so a value cannot tear
    // // across the asynchronous JTAG read.
    // wire [3:0] probe_sel;

    // altsource_probe #(
    //     .sld_auto_instance_index ("YES"),
    //     .sld_instance_index      (0),
    //     .instance_id             ("BNCH"),
    //     .probe_width             (32),
    //     .source_width            (4),
    //     .source_initial_value    ("0"),
    //     .enable_metastability    ("NO"),
    //     .lpm_type                ("altsource_probe")
    // ) u_isp (
    //     .probe      (readout(probe_sel)),
    //     .source     (probe_sel),
    //     .source_clk (CLOCK_50),
    //     .source_ena (1'b1)
    // );

    // 7-segment decoder, active-low segments
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

// debouncer, emit one cycle pulse on press
module debounce_pulse #(parameter STABLE = 16) (
    input  wire clk,
    input  wire rst,
    input  wire btn_n,
    output reg  pulse
);
    // 2-FF synchronizer; s1 is the pressed level, active-high
    reg s0, s1;
    always @(posedge clk) begin
        s0 <= ~btn_n;
        s1 <= s0;
    end

    // add to a counter only when the synced input differs from the last
    // accepted stable level; accept the new level only once the counter is full
    reg [STABLE-1:0] cnt;
    reg              stable_lvl;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt        <= {STABLE{1'b0}};
            stable_lvl <= 1'b0;
        end else if (s1 == stable_lvl) begin
            cnt <= {STABLE{1'b0}};
        end else begin
            cnt <= cnt + 1'b1;
            if (&cnt) stable_lvl <= s1;
        end
    end

    // rising-edge detect on the debounced level = one pulse per press
    reg stable_d;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            stable_d <= 1'b0;
            pulse    <= 1'b0;
        end else begin
            stable_d <= stable_lvl;
            pulse    <= stable_lvl & ~stable_d;
        end
    end
endmodule
