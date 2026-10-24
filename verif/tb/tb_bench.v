`timescale 1ns/1ps

// Simulation twin of the board's benchmark counters.
//
// Mirrors soc_top.v exactly: same halt condition, same freeze (the CPU's
// clk_en drops two clocks after the halt, through the same synchronizer), same
// x28..x31 capture, same readout words.  Run a benchmark here first and it
// tells you all 16 words the board must report (word<n>= lines, n = the JTAG
// selector); if the board disagrees, the difference is real hardware
// behaviour, not a modelling artefact.
//
// Reads program.hex from the directory vvp is started in; the caller
// (quartus/bench.py) runs it inside the benchmark's own build folder, so no
// path ever passes through Verilog.
//
//   +max=<n>         cycle ceiling before declaring a hang (default 20,000,000)
//   +clken=<mode>    clk_en pattern: full (default), half (the board's 25 MHz
//                    setting) or rand; counters only advance on enabled
//                    cycles, as on the board.  Misses are served at the raw
//                    clock rate, so `cycles` (CPU cycles) depends on the mode;
//                    every other number is the same in all of them
//
// The SRAM model starts zeroed, standing in for the board's reset sweep that
// zeroes the data region (CLEAR_SRAM=1 in soc_top.v); the sweep itself is not
// counted on the board either.
//   +seed=<n>        seed for +clken=rand (default 1)
//   +speed=<n>       SW9:8 value to report in the status word (default 3)
module tb_bench;

    reg clk     = 0;
    reg rst     = 1;
    reg clk_en  = 1;            // the speed setting's pattern (soc_top's clk_en_sel)
    wire cpu_clk_en;            // ... frozen after the halt

    wire [31:0] dbg_pc, dbg_instr, dbg_wb_data, dbg_if_pc;
    wire        dbg_reg_write, dbg_retire_valid, dbg_stall, dbg_redirect;
    wire        mem_ready, dbg_dmiss, dbg_dwriteback, dbg_imiss;

    wire [17:0] SRAM_ADDR;
    wire [15:0] SRAM_DQ;
    wire        SRAM_CE_N, SRAM_OE_N, SRAM_WE_N, SRAM_UB_N, SRAM_LB_N;

    pipelined_datapath #(.IMEM_INIT("")) dut (
        .clk              (clk),
        .rst              (rst),
        .clk_en           (cpu_clk_en),
        .dbg_pc           (dbg_pc),
        .dbg_instr        (dbg_instr),
        .dbg_wb_data      (dbg_wb_data),
        .dbg_reg_write    (dbg_reg_write),
        .dbg_if_pc        (dbg_if_pc),
        .dbg_retire_valid (dbg_retire_valid),
        .dbg_stall        (dbg_stall),
        .dbg_redirect     (dbg_redirect),
        .dbg_mem_ready    (mem_ready),
        .dbg_dmiss        (dbg_dmiss),
        .dbg_dwriteback   (dbg_dwriteback),
        .dbg_imiss        (dbg_imiss),
        .SRAM_ADDR        (SRAM_ADDR),
        .SRAM_DQ          (SRAM_DQ),
        .SRAM_CE_N        (SRAM_CE_N),
        .SRAM_OE_N        (SRAM_OE_N),
        .SRAM_WE_N        (SRAM_WE_N),
        .SRAM_UB_N        (SRAM_UB_N),
        .SRAM_LB_N        (SRAM_LB_N)
    );

    sram_model #(.ABITS(18), .ZERO_INIT(1)) u_sram (
        .SRAM_ADDR (SRAM_ADDR),
        .SRAM_DQ   (SRAM_DQ),
        .SRAM_CE_N (SRAM_CE_N),
        .SRAM_OE_N (SRAM_OE_N),
        .SRAM_WE_N (SRAM_WE_N),
        .SRAM_UB_N (SRAM_UB_N),
        .SRAM_LB_N (SRAM_LB_N)
    );

    always #5 clk = ~clk;

    reg [8*4-1:0] clken_mode;
    integer       seed;

    // clk_en for the next rising edge is picked just after this one
    always @(posedge clk) begin
        #1;
        if      (clken_mode == "half") clk_en = !clk_en;
        else if (clken_mode == "rand") clk_en = $random(seed);
        else                           clk_en = 1'b1;
    end

    localparam [31:0] HALT_INSTR = 32'h0000_006F;

    reg        halted  = 0;
    reg        halted_s0 = 0, halted_s1 = 0;
    always @(posedge clk) begin
        halted_s0 <= halted;
        halted_s1 <= halted_s0;
    end
    assign cpu_clk_en = clk_en && !halted_s1;

    reg [31:0] cyc     = 0, retired = 0, stalls = 0, flushes = 0;
    reg [31:0] dmisses = 0, dwbacks = 0, imisses = 0;
    reg [31:0] result0 = 0, result1 = 0, result2 = 0, result3 = 0;

    wire [4:0] retire_rd = dbg_instr[11:7];
    wire       capture   = dbg_retire_valid && dbg_reg_write &&
                           (retire_rd[4:2] == 3'b111) && !halted;

    // same edge, same order of effects as the wrapper: the halting `j .` is
    // itself counted, then everything freezes; disabled cycles count nothing
    always @(posedge clk) begin
        if (rst) begin
            halted  <= 0; cyc <= 0; retired <= 0; stalls <= 0; flushes <= 0;
            result0 <= 0; result1 <= 0; result2 <= 0; result3 <= 0;
        end else if (cpu_clk_en && !halted && mem_ready) begin
            cyc <= cyc + 1;
            if (dbg_retire_valid) retired <= retired + 1;
            if (dbg_stall)        stalls  <= stalls  + 1;
            if (dbg_redirect)     flushes <= flushes + 1;
            if (dbg_retire_valid && (dbg_instr == HALT_INSTR)) halted <= 1;
            if (capture) begin
                case (retire_rd[1:0])
                    2'd0: result0 <= dbg_wb_data;
                    2'd1: result1 <= dbg_wb_data;
                    2'd2: result2 <= dbg_wb_data;
                    2'd3: result3 <= dbg_wb_data;
                endcase
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            dmisses <= 0; dwbacks <= 0; imisses <= 0;
        end else if (!halted) begin
            if (dbg_dmiss)      dmisses <= dmisses + 1;
            if (dbg_dwriteback) dwbacks <= dwbacks + 1;
            if (dbg_imiss)      imisses <= imisses + 1;
        end
    end

    integer maxcyc, speed, n;

    // soc_top.v's status word and readout mux, word for word
    wire [31:0] status = {8'hA5, 8'd3, 8'd0, dbg_redirect, dbg_stall, dbg_retire_valid,
                          dbg_reg_write, mem_ready, speed[1:0], halted};

    function [31:0] readout(input [3:0] sel);
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
            4'd13: readout = dmisses;
            4'd14: readout = dwbacks;
            default: readout = imisses;
        endcase
    endfunction

    initial begin
        if (!$value$plusargs("max=%d", maxcyc)) maxcyc = 20000000;
        if (!$value$plusargs("clken=%s", clken_mode)) clken_mode = "full";
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("speed=%d", speed)) speed = 3;
        if (clken_mode != "full" && clken_mode != "half" && clken_mode != "rand") begin
            $display("ERROR: +clken must be full, half or rand");
            $finish;
        end

        #1 $readmemh("program.hex", dut.u_icache.u_data.mem);   // the board's I-cache preload
        repeat (3) @(posedge clk);
        #1 rst = 0;

        while (!halted && cyc < maxcyc) @(posedge clk);
        repeat (8) @(posedge clk);      // let the freeze take hold, as it does on the board
        #1;

        if (!halted) begin
            $display("HANG: no `j .` retired within %0d cycles", maxcyc);
            $display("      last retired pc=%08x instr=%08x", dbg_pc, dbg_instr);
            $finish;
        end

        $display("HALTED");
        for (n = 0; n < 16; n = n + 1)
            $display("word%0d=%0d", n, readout(n));
        if (u_sram.errors != 0)
            $display("ERROR: the SRAM model saw %0d timing violation(s)", u_sram.errors);
        $finish;
    end
endmodule
