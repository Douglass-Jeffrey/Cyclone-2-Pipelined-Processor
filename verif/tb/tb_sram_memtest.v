`timescale 1ns/1ps

// Unit test for quartus/sram_test/sram_memtest.v, against verif/tb/sram_model.v.
// Three copies run side by side:
//   clean       a perfect SRAM: every round must pass, with no timing errors
//   addr fault  word-address bit 4 stuck at 0: word 16 lands on word 0, so the
//               first verify must fail at byte 0 (expected 0000, got 0010)
//   data fault  DQ bit 5 stuck at 0: the first word with bit 5 set, word 32,
//               must fail at byte 64 (expected 0020, got 0000)
//
//   ADDR_BITS  10 (1 KB) by default; -P tb_sram_memtest.ADDR_BITS=19 runs the
//              full 512 KB (slow), -P tb_sram_memtest.ROUNDS=1 shortens it
module tb_sram_memtest;
    parameter ADDR_BITS = 10;
    parameter ROUNDS    = 2;
    localparam AB = ADDR_BITS - 1;              // SRAM word address bits

    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;                      // 50 MHz

    integer failures = 0;

    // ---- clean ----
    wire [31:0] c_rounds, c_errors, c_addr;
    wire [15:0] c_exp, c_got;
    wire [AB-1:0] c_A; wire [15:0] c_DQ; wire c_CE, c_OE, c_WE, c_UB, c_LB;
    sram_memtest #(.ADDR_BITS(ADDR_BITS)) u_clean (
        .clk(clk), .rst(rst), .rounds(c_rounds), .errors(c_errors), .first_addr(c_addr),
        .first_expected(c_exp), .first_got(c_got), .phase(),
        .SRAM_ADDR(c_A), .SRAM_DQ(c_DQ), .SRAM_CE_N(c_CE), .SRAM_OE_N(c_OE), .SRAM_WE_N(c_WE),
        .SRAM_UB_N(c_UB), .SRAM_LB_N(c_LB));
    sram_model #(.ABITS(AB)) m_clean (
        .SRAM_ADDR(c_A), .SRAM_DQ(c_DQ), .SRAM_CE_N(c_CE), .SRAM_OE_N(c_OE), .SRAM_WE_N(c_WE),
        .SRAM_UB_N(c_UB), .SRAM_LB_N(c_LB));

    // ---- stuck address bit ----
    wire [31:0] a_rounds, a_errors, a_addr;
    wire [15:0] a_exp, a_got;
    wire [AB-1:0] a_A; wire [15:0] a_DQ; wire a_CE, a_OE, a_WE, a_UB, a_LB;
    sram_memtest #(.ADDR_BITS(ADDR_BITS)) u_afault (
        .clk(clk), .rst(rst), .rounds(a_rounds), .errors(a_errors), .first_addr(a_addr),
        .first_expected(a_exp), .first_got(a_got), .phase(),
        .SRAM_ADDR(a_A), .SRAM_DQ(a_DQ), .SRAM_CE_N(a_CE), .SRAM_OE_N(a_OE), .SRAM_WE_N(a_WE),
        .SRAM_UB_N(a_UB), .SRAM_LB_N(a_LB));
    sram_model #(.ABITS(AB), .STUCK_ADDR_BIT(4)) m_afault (
        .SRAM_ADDR(a_A), .SRAM_DQ(a_DQ), .SRAM_CE_N(a_CE), .SRAM_OE_N(a_OE), .SRAM_WE_N(a_WE),
        .SRAM_UB_N(a_UB), .SRAM_LB_N(a_LB));

    // ---- stuck data bit ----
    wire [31:0] d_rounds, d_errors, d_addr;
    wire [15:0] d_exp, d_got;
    wire [AB-1:0] d_A; wire [15:0] d_DQ; wire d_CE, d_OE, d_WE, d_UB, d_LB;
    sram_memtest #(.ADDR_BITS(ADDR_BITS)) u_dfault (
        .clk(clk), .rst(rst), .rounds(d_rounds), .errors(d_errors), .first_addr(d_addr),
        .first_expected(d_exp), .first_got(d_got), .phase(),
        .SRAM_ADDR(d_A), .SRAM_DQ(d_DQ), .SRAM_CE_N(d_CE), .SRAM_OE_N(d_OE), .SRAM_WE_N(d_WE),
        .SRAM_UB_N(d_UB), .SRAM_LB_N(d_LB));
    sram_model #(.ABITS(AB), .STUCK_DQ_BIT(5)) m_dfault (
        .SRAM_ADDR(d_A), .SRAM_DQ(d_DQ), .SRAM_CE_N(d_CE), .SRAM_OE_N(d_OE), .SRAM_WE_N(d_WE),
        .SRAM_UB_N(d_UB), .SRAM_LB_N(d_LB));

    task expect(input cond, input [511:0] name);
        begin
            if (cond) $display("ok   %0s", name);
            else begin $display("FAIL %0s", name); failures = failures + 1; end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1 rst = 0;
        wait (c_rounds == ROUNDS);
        @(posedge clk); #1;

        $display("clean      rounds=%0d errors=%0d", c_rounds, c_errors);
        $display("addr fault errors=%0d first byte=%0h expected=%h got=%h", a_errors, a_addr, a_exp, a_got);
        $display("data fault errors=%0d first byte=%0h expected=%h got=%h", d_errors, d_addr, d_exp, d_got);

        expect(c_errors == 0,                    "clean SRAM: every round passes");
        expect(m_clean.errors == 0,              "clean SRAM: no timing violations");
        expect(a_errors != 0 && a_addr == 32'h0 && a_exp == 16'h0000 && a_got == 16'h0010,
               "stuck address bit caught, first at byte 0");
        expect(d_errors != 0 && d_addr == 32'h40 && d_exp == 16'h0020 && d_got == 16'h0000,
               "stuck data bit caught, first at byte 0x40");
        expect(m_afault.errors == 0 && m_dfault.errors == 0, "faulty SRAMs: no timing violations");

        if (failures == 0) $display("SRAM MEMTEST CHECK: ALL PASSED");
        else               $display("SRAM MEMTEST CHECK: %0d FAILURE(S)", failures);
        $finish;
    end
endmodule
