`timescale 1ns/1ps

// Simulation twin of the board's benchmark counters.
//
// Mirrors soc_top.v exactly: same halt condition, same freeze semantics, same
// x28..x31 capture.  Run a benchmark here first and it tells you the numbers
// the board must report; if the board disagrees, the difference is real
// hardware behaviour, not a modelling artefact.
//
// Reads program.hex from the directory vvp is started in; the caller
// (quartus/bench.py) runs it inside the benchmark's own build folder, so no
// path ever passes through Verilog.
//
//   +max=<n>         cycle ceiling before declaring a hang (default 20,000,000)
module tb_bench;

    reg clk = 0;
    reg rst = 1;

    wire [31:0] dbg_pc, dbg_instr, dbg_wb_data, dbg_if_pc;
    wire        dbg_reg_write, dbg_retire_valid, dbg_stall, dbg_redirect;

    pipelined_datapath #(.IMEM_INIT("")) dut (
        .clk              (clk),
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

    localparam [31:0] HALT_INSTR = 32'h0000_006F;

    reg        halted  = 0;
    reg [31:0] cyc     = 0, retired = 0, stalls = 0, flushes = 0;
    reg [31:0] result0 = 0, result1 = 0, result2 = 0, result3 = 0;

    wire [4:0] retire_rd = dbg_instr[11:7];
    wire       capture   = dbg_retire_valid && dbg_reg_write &&
                           (retire_rd[4:2] == 3'b111) && !halted;

    // same edge, same order of effects as the wrapper: the halting `j .` is
    // itself counted, then everything freezes
    always @(posedge clk) begin
        if (rst) begin
            halted  <= 0; cyc <= 0; retired <= 0; stalls <= 0; flushes <= 0;
            result0 <= 0; result1 <= 0; result2 <= 0; result3 <= 0;
        end else if (!halted) begin
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

    integer maxcyc;

    initial begin
        if (!$value$plusargs("max=%d", maxcyc)) maxcyc = 20000000;

        #1 $readmemh("program.hex", dut.u_imem.mem);
        repeat (3) @(posedge clk);
        #1 rst = 0;

        while (!halted && cyc < maxcyc) @(posedge clk);
        #1;

        if (!halted) begin
            $display("HANG: no `j .` retired within %0d cycles", maxcyc);
            $display("      last retired pc=%08x instr=%08x", dbg_pc, dbg_instr);
            $finish;
        end

        $display("HALTED");
        $display("cycles=%0d",  cyc);
        $display("retired=%0d", retired);
        $display("stalls=%0d",  stalls);
        $display("flushes=%0d", flushes);
        $display("x28=%0d", result0);
        $display("x29=%0d", result1);
        $display("x30=%0d", result2);
        $display("x31=%0d", result3);
        $display("haltpc=%0d", dbg_pc);
        $display("haltinstr=%0d", dbg_instr);
        $display("haltwb=%0d", dbg_wb_data);
        $display("haltifpc=%0d", dbg_if_pc);
        $finish;
    end
endmodule
