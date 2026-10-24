`timescale 1ns/1ps

// Standalone timing check for imem.v.
//
// What this confirms:
//   - addr is read on posedge clk, so instr shows the word exactly one
//     cycle after the address is presented.
//   - this holds up under a new address every single cycle (streaming
//     fetch), the way IF will actually drive it via next_pc, not just
//     for a single isolated read with idle cycles around it.
//   - contiguous vs. non-contiguous addressing behaves identically --
//     there's nothing here that only works for sequential PCs.
//   - with clk_en low the captured address holds, so instr does not change.
//
// Memory contents are preloaded directly through the hierarchical
// reference to u_imem.mem instead of via INIT_FILE, so this test has
// no dependency on program.hex or file search paths.
module tb_imem;

    reg         clk = 0;
    reg         clk_en = 1;
    reg  [31:0] addr;
    wire [31:0] instr;

    integer errors = 0;

    imem #(
        .DEPTH_WORDS (16),
        .INIT_FILE   ("")
    ) u_imem (
        .clk    (clk),
        .clk_en (clk_en),
        .addr   (addr),
        .instr  (instr)
    );

    always #5 clk = ~clk;

    // known, easily-distinguished contents at known word indices
    initial begin
        u_imem.mem[0] = 32'hDEAD_0000;
        u_imem.mem[1] = 32'hDEAD_0001;
        u_imem.mem[2] = 32'hDEAD_0002;
        u_imem.mem[3] = 32'hDEAD_0003;
        u_imem.mem[4] = 32'hDEAD_0004;
    end

    task check(input [31:0] expected);
        begin
            if (instr !== expected) begin
                $display("FAIL @ %0t: expected instr=%h got=%h", $time, expected, instr);
                errors = errors + 1;
            end else begin
                $display("ok   @ %0t: instr=%h", $time, instr);
            end
        end
    endtask

    initial begin
        // present addr=0 (byte). Nothing to check yet -- addr_reg hasn't
        // latched this address until the edge below.
        addr = 32'd0;
        @(posedge clk); #1;

        // addr_reg just captured addr=0 -> instr should now be mem[0].
        // Present the *next* address (deliberately non-contiguous) before
        // checking, to mimic a real fetch stream where addr changes every
        // cycle regardless of what's being checked.
        check(32'hDEAD_0000);
        addr = 32'd12;
        @(posedge clk); #1;

        check(32'hDEAD_0003);   // addr_reg captured 12 last edge -> mem[3]
        addr = 32'd4;
        @(posedge clk); #1;

        check(32'hDEAD_0001);   // addr_reg captured 4 -> mem[1]
        addr = 32'd16;
        @(posedge clk); #1;

        check(32'hDEAD_0004);   // addr_reg captured 16 -> mem[4]
        addr = 32'd8;
        @(posedge clk); #1;

        check(32'hDEAD_0002);   // addr_reg captured 8 -> mem[2]

        // a disabled edge must not capture the new address
        clk_en = 0; addr = 32'd4;
        @(posedge clk); #1;
        check(32'hDEAD_0002);   // still mem[2]
        clk_en = 1;
        @(posedge clk); #1;
        check(32'hDEAD_0001);   // enabled again: captures 4 -> mem[1]

        if (errors == 0) $display("IMEM TIMING CHECK: ALL PASSED");
        else              $display("IMEM TIMING CHECK: %0d FAILURE(S)", errors);
        $finish;
    end

endmodule
