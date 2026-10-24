`timescale 1ns/1ps

// Standalone timing + correctness check for sram_ctl.v, against
// verif/tb/sram_model.v, a behavioral model of the async SRAM chip itself
// (not the DUT) that also checks the chip's timing rules.
//
// What this confirms:
//   - a full 128-bit line write, followed by a read of the same line,
//     comes back byte-for-byte identical through 8 real 16-bit beats.
//   - a second, independent line at a different address doesn't alias.
//   - back-to-back requests (req held high, as a cache will drive it) each
//     get exactly one transfer.
//   - the model saw no timing violation: address and data settle before
//     WE_N falls and hold after it rises, reads sample after the access time,
//     and DQ is never driven from both ends.
//   - OE_N and WE_N are never asserted together, and SRAM_UB_N/LB_N stay low.
module tb_sram_ctl;

    localparam ADDR_BITS   = 10;   // small address space for sim: 1KB, 64 lines
    localparam WAIT_CYCLES = 2;

    reg         clk = 0;
    reg         rst;
    reg         req;
    reg         we;
    reg  [31:0] addr;
    reg  [127:0] wdata;
    wire [127:0] rdata;
    wire         ack;

    wire [ADDR_BITS-2:0] SRAM_ADDR;
    wire [15:0]          SRAM_DQ;
    wire                 SRAM_CE_N, SRAM_OE_N, SRAM_WE_N, SRAM_UB_N, SRAM_LB_N;

    integer errors = 0;
    integer t_req, cycles = 0;

    sram_ctl #(
        .ADDR_BITS   (ADDR_BITS),
        .WAIT_CYCLES (WAIT_CYCLES)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .req       (req),
        .we        (we),
        .addr      (addr),
        .wdata     (wdata),
        .rdata     (rdata),
        .ack       (ack),
        .SRAM_ADDR (SRAM_ADDR),
        .SRAM_DQ   (SRAM_DQ),
        .SRAM_CE_N (SRAM_CE_N),
        .SRAM_OE_N (SRAM_OE_N),
        .SRAM_WE_N (SRAM_WE_N),
        .SRAM_UB_N (SRAM_UB_N),
        .SRAM_LB_N (SRAM_LB_N)
    );

    sram_model #(.ABITS(ADDR_BITS-1)) u_sram (
        .SRAM_ADDR (SRAM_ADDR),
        .SRAM_DQ   (SRAM_DQ),
        .SRAM_CE_N (SRAM_CE_N),
        .SRAM_OE_N (SRAM_OE_N),
        .SRAM_WE_N (SRAM_WE_N),
        .SRAM_UB_N (SRAM_UB_N),
        .SRAM_LB_N (SRAM_LB_N)
    );

    always #10 clk = ~clk;   // 50MHz-equivalent period
    always @(posedge clk) cycles = cycles + 1;

    task do_req(input r_we, input [31:0] r_addr, input [127:0] r_wdata);
        begin
            @(posedge clk);
            req = 1; we = r_we; addr = r_addr; wdata = r_wdata;
            @(posedge clk);
            while (!ack) @(posedge clk);
            req = 0;
            #1;
        end
    endtask

    task check(input [127:0] expected, input [511:0] name);
        begin
            if (rdata !== expected) begin
                $display("FAIL %0s @ %0t: expected=%h got=%h", name, $time, expected, rdata);
                errors = errors + 1;
            end else begin
                $display("ok   %0s @ %0t: rdata=%h", name, $time, rdata);
            end
        end
    endtask

    // line k's test data: every 16-bit word distinct, both polarities
    function [127:0] line_data(input integer k);
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1)
                line_data[16*b +: 16] = {k[7:0], b[3:0], 4'hA} ^ ((k & 1) ? 16'hFFFF : 16'h0000);
        end
    endfunction

    integer k, n_ack;

    initial begin
        rst = 1; req = 0; we = 0; addr = 0; wdata = 0;
        @(posedge clk); @(posedge clk);
        rst = 0;

        // ---- 1: write a line, read it back ----
        t_req = cycles;
        do_req(1'b1, 32'h0000_0000, 128'h1122_3344_5566_7788_99AA_BBCC_DDEE_FF00);
        $display("info  one line write took %0d cycles from req to ack", cycles - t_req);
        do_req(1'b0, 32'h0000_0000, 128'h0);
        check(128'h1122_3344_5566_7788_99AA_BBCC_DDEE_FF00, "line0 read after write");

        // ---- 2: a different, non-16-byte-aligned-looking line doesn't alias ----
        do_req(1'b1, 32'h0000_0030, 128'hCAFE_BABE_0000_0000_0000_0000_DEAD_BEEF);
        do_req(1'b0, 32'h0000_0030, 128'h0);
        check(128'hCAFE_BABE_0000_0000_0000_0000_DEAD_BEEF, "line at 0x30 read after write");

        // line0 must still hold its original data -- no aliasing
        do_req(1'b0, 32'h0000_0000, 128'h0);
        check(128'h1122_3344_5566_7788_99AA_BBCC_DDEE_FF00, "line0 unchanged by other write");

        // ---- 3: back-to-back writes with req held high, then read them back ----
        @(posedge clk);
        req = 1; we = 1; k = 4; addr = k * 16; wdata = line_data(k); n_ack = 0;
        while (k < 12) begin
            @(posedge clk);
            if (ack) begin
                n_ack = n_ack + 1;
                k = k + 1; addr = k * 16; wdata = line_data(k);   // next request, req stays high
            end
        end
        req = 0;
        if (n_ack != 8) begin
            $display("FAIL back-to-back writes: %0d acks for 8 requests", n_ack);
            errors = errors + 1;
        end
        for (k = 4; k < 12; k = k + 1) begin
            do_req(1'b0, k * 16, 128'h0);
            check(line_data(k), "back-to-back line read back");
        end

        if (u_sram.errors != 0) begin
            $display("FAIL the SRAM model saw %0d timing violation(s)", u_sram.errors);
            errors = errors + 1;
        end else
            $display("ok   SRAM model saw no timing violations");

        if (errors == 0) $display("SRAM_CTL CHECK: ALL PASSED");
        else              $display("SRAM_CTL CHECK: %0d FAILURE(S)", errors);
        $finish;
    end

    // ---- beat-sequencing / timing assertion ----
    // while a transfer is running (CE_N low), OE_N and WE_N must never both
    // be asserted, and UB_N/LB_N must stay low.
    always @(posedge clk) begin
        if (!SRAM_CE_N) begin
            if (!SRAM_OE_N && !SRAM_WE_N) begin
                $display("FAIL @ %0t: OE_N and WE_N asserted together", $time);
                errors = errors + 1;
            end
            if (SRAM_UB_N !== 1'b0 || SRAM_LB_N !== 1'b0) begin
                $display("FAIL @ %0t: byte lane disabled mid-transfer", $time);
                errors = errors + 1;
            end
        end
    end

endmodule
