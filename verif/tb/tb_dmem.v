`timescale 1ns/1ps

// Standalone timing + correctness check for dmem.v.
//
// What this confirms:
//   - a store commits synchronously off the *live* address the same
//     cycle it's presented -- no delay, unaffected by the read side's
//     registered address (this is exactly the widx_w/boff_w vs.
//     widx_r/boff_r split we added).
//   - a load returns data exactly one cycle after addr/funct3/mem_read
//     are presented (registered-address / combinational-dout, same
//     idiom as imem).
//   - byte/halfword alignment, sign vs. zero extension, and byte-lane
//     independence on stores all still work correctly through that
//     registered read path.
//   - rdata is forced to 0 when mem_read is low, even with a stale
//     addr_reg sitting behind it from an earlier access.
//   - with clk_en low nothing commits and a pending load result holds.
module tb_dmem;

    reg         clk = 0;
    reg         clk_en = 1;
    reg         valid = 1;
    reg  [31:0] addr;
    reg  [2:0]  funct3;
    reg         mem_read;
    reg         mem_write;
    reg  [31:0] wdata;
    wire [31:0] rdata;

    integer errors = 0;

    dmem #(
        .DEPTH_WORDS (16),
        .INIT_FILE   ("")
    ) u_dmem (
        .clk       (clk),
        .clk_en    (clk_en),
        .valid     (valid),
        .addr      (addr),
        .funct3    (funct3),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .wdata     (wdata),
        .rdata     (rdata)
    );

    always #5 clk = ~clk;

    task check(input [31:0] expected, input [511:0] name);
        begin
            if (rdata !== expected) begin
                $display("FAIL %0s @ %0t: expected=%h got=%h", name, $time, expected, rdata);
                errors = errors + 1;
            end else begin
                $display("ok   %0s @ %0t: rdata=%h", name, $time, rdata);
            end
        end
    endtask

    initial begin
        addr = 0; funct3 = 0; mem_read = 0; mem_write = 0; wdata = 0;

        // ---- 1: SW then LW to the same address ----
        // store commits this same cycle off the live address
        addr = 32'd0; funct3 = 3'b010; wdata = 32'hCAFE_BABE; mem_write = 1;
        @(posedge clk); #1;
        mem_write = 0;

        // read request presented now; result isn't valid until the NEXT edge
        addr = 32'd0; funct3 = 3'b010; mem_read = 1;
        @(posedge clk); #1;
        check(32'hCAFE_BABE, "LW after SW");
        mem_read = 0;

        // ---- 2: byte-lane independence (4x SB must not clobber neighbors) ----
        addr = 32'd12; funct3 = 3'b000; wdata = 32'h0000_0011; mem_write = 1;
        @(posedge clk); #1;
        addr = 32'd13; wdata = 32'h0000_0022;
        @(posedge clk); #1;
        addr = 32'd14; wdata = 32'h0000_0033;
        @(posedge clk); #1;
        addr = 32'd15; wdata = 32'h0000_0044;
        @(posedge clk); #1;
        mem_write = 0;

        addr = 32'd12; funct3 = 3'b010; mem_read = 1;   // LW
        @(posedge clk); #1;
        check(32'h4433_2211, "LW after 4x SB");
        mem_read = 0;

        // ---- 3: halfword sign vs. zero extension ----
        addr = 32'd16; funct3 = 3'b001; wdata = 32'hFFFF_EDCC; mem_write = 1;  // SH
        @(posedge clk); #1;
        mem_write = 0;

        addr = 32'd16; funct3 = 3'b001; mem_read = 1;    // LH -- sign-extend
        @(posedge clk); #1;
        check(32'hFFFF_EDCC, "LH sign-extend");
        mem_read = 0;

        addr = 32'd16; funct3 = 3'b101; mem_read = 1;    // LHU -- zero-extend
        @(posedge clk); #1;
        check(32'h0000_EDCC, "LHU zero-extend");
        mem_read = 0;

        // ---- 4: byte sign vs. zero extension ----
        addr = 32'd20; funct3 = 3'b000; wdata = 32'hFFFF_FF80; mem_write = 1;  // SB
        @(posedge clk); #1;
        mem_write = 0;

        addr = 32'd20; funct3 = 3'b000; mem_read = 1;    // LB -- sign-extend
        @(posedge clk); #1;
        check(32'hFFFF_FF80, "LB sign-extend");
        mem_read = 0;

        addr = 32'd20; funct3 = 3'b100; mem_read = 1;    // LBU -- zero-extend
        @(posedge clk); #1;
        check(32'h0000_0080, "LBU zero-extend");
        mem_read = 0;

        // ---- 5: mem_read low -> rdata forced to 0, even with addr_reg
        //         still pointing at the last real read address ----
        mem_read = 0; mem_write = 0;
        @(posedge clk); #1;
        check(32'h0000_0000, "rdata is 0 when mem_read deasserted");

        // ---- 6: valid=0 (a bubble) must neither store nor load, even with
        //         stale mem_write / mem_read still asserted ----
        valid = 0;
        addr = 32'd0; funct3 = 3'b010; wdata = 32'h1111_1111; mem_write = 1;
        @(posedge clk); #1;                       // would overwrite word 0 if not gated
        mem_write = 0; mem_read = 1;
        @(posedge clk); #1;
        check(32'h0000_0000, "bubble load returns 0");
        valid = 1;
        addr = 32'd0; mem_read = 1;
        @(posedge clk); #1;
        check(32'hCAFE_BABE, "word 0 untouched by bubble store");
        mem_read = 0;

        // ---- 7: the load in WB keeps its data when the NEXT slot is a bubble
        //         (valid must not gate rdata, only the latched request) ----
        addr = 32'd0; funct3 = 3'b010; mem_read = 1; valid = 1;
        @(posedge clk); #1;
        valid = 0; mem_read = 0;                  // slot behind the load is a bubble
        check(32'hCAFE_BABE, "load data survives a bubble behind it");

        // ---- 8: clk_en low freezes the memory: a store on disabled edges
        //         never commits, and the pending load result holds ----
        valid = 1; funct3 = 3'b010; addr = 32'd0;
        clk_en = 0; mem_read = 0; mem_write = 1; wdata = 32'h2222_2222;
        @(posedge clk); #1;
        @(posedge clk); #1;
        check(32'hCAFE_BABE, "load result held while clk_en low");
        clk_en = 1; mem_write = 0; mem_read = 1;
        @(posedge clk); #1;
        check(32'hCAFE_BABE, "word 0 untouched by store on disabled edges");
        mem_read = 0;

        if (errors == 0) $display("DMEM CHECK: ALL PASSED");
        else              $display("DMEM CHECK: %0d FAILURE(S)", errors);
        $finish;
    end

endmodule
