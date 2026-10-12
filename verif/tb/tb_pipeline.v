`timescale 1ns/1ps

// Main TB for the pipeline, run by verif/run_directed_tests.py and
// verif/run_randomized_tests.py.
//
//   program.hex     read:    program image (one 32-bit hex word per line)
//   trace.txt       written: one line per retired instruction
//   dump.txt        written: final regfile and data memory
//   +cycles=<n>     how many ENABLED cycles to run after reset (default 2000)
//   +clken=<mode>   clk_en pattern: full (default), half (the board's 25 MHz
//                   setting) or rand (random enables, ~50%)
//   +seed=<n>       seed for +clken=rand (default 1)
//
// Every count and trace line is taken on enabled cycles only, so a correct
// pipeline produces identical output in every +clken mode.
module tb_pipeline;

    reg clk     = 0;
    reg rst     = 1;
    reg clk_en  = 1;

    wire [31:0] dbg_pc, dbg_instr, dbg_wb_data, dbg_if_pc;
    wire        dbg_reg_write, dbg_retire_valid, dbg_stall, dbg_redirect;

    // no INIT_FILE: the program is loaded below through the hierarchy
    pipelined_datapath #(.IMEM_INIT("")) dut (
        .clk              (clk),
        .clk_en           (clk_en),
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

    always #5 clk = ~clk;

    reg [8*4-1:0] clken_mode;
    integer       seed;

    // clk_en for the next rising edge is picked just after this one, so it is
    // stable by the time the falling-edge sampler below reads it
    always @(posedge clk) begin
        #1;
        if      (clken_mode == "half") clk_en = !clk_en;
        else if (clken_mode == "rand") clk_en = $random(seed);
        else                           clk_en = 1'b1;
    end

    integer ncycles;
    integer tfd, dfd, i;
    integer en_cycles = 0, clocks = 0;
    integer retired = 0, stalls = 0, flushes = 0;

    // sample on the falling edge so we never race the rising-edge updates;
    // a disabled edge moves nothing, so it must not count or trace anything
    always @(negedge clk) begin
        if (!rst && clk_en) begin
            en_cycles = en_cycles + 1;
            if (dbg_stall)    stalls  = stalls  + 1;
            if (dbg_redirect) flushes = flushes + 1;
            if (dbg_retire_valid) begin
                retired = retired + 1;
                $fdisplay(tfd, "%08x %08x %0d %02x %08x",
                          dbg_pc, dbg_instr,
                          (dut.reg_write && dut.rd_addr != 5'd0),
                          (dut.reg_write && dut.rd_addr != 5'd0) ? dut.rd_addr : 5'd0,
                          (dut.reg_write && dut.rd_addr != 5'd0) ? dut.wb_data : 32'd0);
            end
        end
    end

    initial begin
        if (!$value$plusargs("cycles=%d", ncycles)) ncycles = 2000;
        if (!$value$plusargs("clken=%s", clken_mode)) clken_mode = "full";
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (clken_mode != "full" && clken_mode != "half" && clken_mode != "rand") begin
            $display("ERROR: +clken must be full, half or rand");
            $finish;
        end

        tfd = $fopen("trace.txt", "w");

        #1 $readmemh("program.hex", dut.u_imem.mem);   // after imem's own zero-fill at t=0

        repeat (3) @(posedge clk);
        #1 rst = 0;
        // the raw-clock cap only guards against clk_en never rising
        while (en_cycles < ncycles && clocks < 64 * ncycles) begin
            @(posedge clk);
            clocks = clocks + 1;
        end
        #1;

        $fclose(tfd);
        dfd = $fopen("dump.txt", "w");
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(dfd, "x%0d %08x", i, dut.u_rf.registers[i]);
        for (i = 0; i < 256; i = i + 1)
            $fdisplay(dfd, "m%0d %08x", i, {dut.u_dmem.mem3[i], dut.u_dmem.mem2[i], dut.u_dmem.mem1[i], dut.u_dmem.mem0[i]});
        $fclose(dfd);

        $display("cycles=%0d clocks=%0d retired=%0d stalls=%0d flushes=%0d",
                 en_cycles, clocks, retired, stalls, flushes);
        $finish;
    end
endmodule
