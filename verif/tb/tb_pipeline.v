`timescale 1ns/1ps

// Main TB for the pipeline, run by verif/run_directed_tests.py and
// verif/run_randomized_tests.py.
//
//   program.hex     read:    program image (one 32-bit hex word per line)
//   trace.txt       written: one line per retired instruction
//   dump.txt        written: final regfile and data memory
//   +cycles=<n>     how long to run after reset (default 2000)
module tb_pipeline;

    reg clk = 0;
    reg rst = 1;

    wire [31:0] dbg_pc, dbg_instr, dbg_wb_data;
    wire        dbg_reg_write;

    // no INIT_FILE: the program is loaded below through the hierarchy
    pipelined_datapath #(.IMEM_INIT("")) dut (
        .clk           (clk),
        .rst           (rst),
        .dbg_pc        (dbg_pc),
        .dbg_instr     (dbg_instr),
        .dbg_wb_data   (dbg_wb_data),
        .dbg_reg_write (dbg_reg_write)
    );

    always #5 clk = ~clk;

    integer ncycles;
    integer tfd, dfd, i;
    integer retired = 0;
    integer stalls  = 0;

    // sample on the falling edge so we never race the rising-edge updates
    always @(negedge clk) begin
        if (!rst) begin
            if (dut.stall) stalls = stalls + 1;
            if (dut.mem_wb_valid) begin
                retired = retired + 1;
                $fdisplay(tfd, "%08x %08x %0d %02x %08x",
                          dut.mem_wb_pc, dut.mem_wb_instr,
                          (dut.reg_write && dut.rd_addr != 5'd0),
                          (dut.reg_write && dut.rd_addr != 5'd0) ? dut.rd_addr : 5'd0,
                          (dut.reg_write && dut.rd_addr != 5'd0) ? dut.wb_data : 32'd0);
            end
        end
    end

    initial begin
        if (!$value$plusargs("cycles=%d", ncycles)) ncycles = 2000;

        tfd = $fopen("trace.txt", "w");

        #1 $readmemh("program.hex", dut.u_imem.mem);   // after imem's own zero-fill at t=0

        repeat (3) @(posedge clk);
        #1 rst = 0;
        repeat (ncycles) @(posedge clk);
        #1;

        $fclose(tfd);
        dfd = $fopen("dump.txt", "w");
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(dfd, "x%0d %08x", i, dut.u_rf.registers[i]);
        for (i = 0; i < 256; i = i + 1)
            $fdisplay(dfd, "m%0d %08x", i, {dut.u_dmem.mem3[i], dut.u_dmem.mem2[i], dut.u_dmem.mem1[i], dut.u_dmem.mem0[i]});
        $fclose(dfd);

        $display("cycles=%0d retired=%0d stalls=%0d", ncycles, retired, stalls);
        $finish;
    end
endmodule
