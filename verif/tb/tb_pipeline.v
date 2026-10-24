`timescale 1ns/1ps

// Main TB for the pipeline, run by verif/run_directed_tests.py and
// verif/run_randomized_tests.py.
//
//   program.hex     read:    program image (one 32-bit hex word per line)
//   trace.txt       written: one line per retired instruction
//   dump.txt        written: final regfile and every NONZERO data-memory word
//   +cycles=<n>     how many cycles of progress to run after reset (default 2000);
//                   cycles spent waiting on a cache miss do not count
//   +clken=<mode>   clk_en pattern: full (default), half (the board's 25 MHz
//                   setting) or rand (random enables, ~50%)
//   +seed=<n>       seed for +clken=rand (default 1)
//   +icache=<mode>  warm (default): the program starts in the I-cache, as on
//                   the board; cold: it starts in the SRAM model's code region
//                   and every line is fetched through a miss
//
// Every count and trace line is taken on edges where the pipeline moves, so a
// correct pipeline produces identical output in every +clken mode.  A data
// miss freezes the whole pipeline, so it changes nothing either; an
// instruction miss only holds the front end, so +icache=cold can shift
// stall and flush counts (never the trace or the results).
module tb_pipeline;

    reg clk     = 0;
    reg rst     = 1;
    reg clk_en  = 1;

    wire [31:0] dbg_pc, dbg_instr, dbg_wb_data, dbg_if_pc;
    wire        dbg_reg_write, dbg_retire_valid, dbg_stall, dbg_redirect;
    wire        dbg_mem_ready, dbg_dmiss, dbg_dwriteback, dbg_imiss;

    wire [17:0] SRAM_ADDR;
    wire [15:0] SRAM_DQ;
    wire        SRAM_CE_N, SRAM_OE_N, SRAM_WE_N, SRAM_UB_N, SRAM_LB_N;

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
        .dbg_redirect     (dbg_redirect),
        .dbg_mem_ready    (dbg_mem_ready),
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

    // starts zeroed, like the reference model's data memory
    sram_model #(.ABITS(18), .ZERO_INIT(1)) u_sram (
        .SRAM_ADDR (SRAM_ADDR),
        .SRAM_DQ   (SRAM_DQ),
        .SRAM_CE_N (SRAM_CE_N),
        .SRAM_OE_N (SRAM_OE_N),
        .SRAM_WE_N (SRAM_WE_N),
        .SRAM_UB_N (SRAM_UB_N),
        .SRAM_LB_N (SRAM_LB_N)
    );

    // SRAM halfword index of each region's first byte (see pipeline.v)
    localparam CODE_HW = 18'h00000;
    localparam DATA_HW = 18'h20000;

    always #5 clk = ~clk;

    reg [8*4-1:0] clken_mode, icache_mode;
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
    integer dmiss = 0, dwb = 0, imiss = 0;

    // sample on the falling edge so we never race the rising-edge updates;
    // an edge where the pipeline holds moves nothing, so it counts nothing
    always @(negedge clk) begin
        if (!rst) begin
            if (dbg_dmiss)      dmiss = dmiss + 1;
            if (dbg_dwriteback) dwb   = dwb   + 1;
            if (dbg_imiss)      imiss = imiss + 1;
        end
        if (!rst && dut.pipe_en) begin
            if (!dut.imiss) en_cycles = en_cycles + 1;
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

    // a data word as the program sees it: from its cache line when that line
    // is present (it may be dirty), else from the SRAM's data region
    function [31:0] data_word(input [15:0] wi);     // word index in the data region
        reg [4:0] tv;
        begin
            tv = dut.u_dcache.u_tag.mem[wi[11:2]];
            if (tv[4] && tv[3:0] == wi[15:12])
                data_word = {dut.u_dcache.lane[3].u_lane.mem[wi[11:0]],
                             dut.u_dcache.lane[2].u_lane.mem[wi[11:0]],
                             dut.u_dcache.lane[1].u_lane.mem[wi[11:0]],
                             dut.u_dcache.lane[0].u_lane.mem[wi[11:0]]};
            else
                data_word = {u_sram.mem[DATA_HW + 2*wi + 1], u_sram.mem[DATA_HW + 2*wi]};
        end
    endfunction

    reg [31:0] prog [0:2047];
    reg [31:0] w;

    initial begin
        if (!$value$plusargs("cycles=%d", ncycles)) ncycles = 2000;
        if (!$value$plusargs("clken=%s", clken_mode)) clken_mode = "full";
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("icache=%s", icache_mode)) icache_mode = "warm";
        if (clken_mode != "full" && clken_mode != "half" && clken_mode != "rand") begin
            $display("ERROR: +clken must be full, half or rand");
            $finish;
        end
        if (icache_mode != "warm" && icache_mode != "cold") begin
            $display("ERROR: +icache must be warm or cold");
            $finish;
        end

        tfd = $fopen("trace.txt", "w");

        // after the RAMs' and the SRAM model's own initialisation at t=0
        #1;
        if (icache_mode == "warm") begin
            $readmemh("program.hex", dut.u_icache.u_data.mem);
        end else begin
            for (i = 0; i < 2048; i = i + 1) prog[i] = 32'd0;
            $readmemh("program.hex", prog);
            for (i = 0; i < 2048; i = i + 1) begin
                u_sram.mem[CODE_HW + 2*i]     = prog[i][15:0];
                u_sram.mem[CODE_HW + 2*i + 1] = prog[i][31:16];
            end
            for (i = 0; i < 512; i = i + 1) dut.u_icache.u_tag.mem[i] = 0;
        end

        repeat (3) @(posedge clk);
        #1 rst = 0;
        // the raw-clock cap only guards against a hang (clk_en never rising,
        // or a miss that never completes)
        while (en_cycles < ncycles && clocks < 64 * ncycles + 4096) begin
            @(posedge clk);
            clocks = clocks + 1;
        end
        #1;

        $fclose(tfd);
        dfd = $fopen("dump.txt", "w");
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(dfd, "x%0d %08x", i, dut.u_rf.registers[i]);
        for (i = 0; i < 65536; i = i + 1) begin
            w = data_word(i);
            if (w !== 32'd0) $fdisplay(dfd, "m%0d %08x", i, w);
        end
        $fclose(dfd);

        if (u_sram.errors != 0)
            $display("ERROR: the SRAM model saw %0d timing violation(s)", u_sram.errors);

        $display("cycles=%0d clocks=%0d retired=%0d stalls=%0d flushes=%0d dmiss=%0d dwb=%0d imiss=%0d",
                 en_cycles, clocks, retired, stalls, flushes, dmiss, dwb, imiss);
        $finish;
    end
endmodule
