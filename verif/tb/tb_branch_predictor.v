`timescale 1ns/1ps

// Unit test for dev/src/branch_predictor.v, run by verif/run_unit_tests.py.
//
// Checks the predictor's contract, not one particular index function:
//   - jal predicted taken to pc+imm; jalr, non-branches and bubbles not taken
//   - reset leaves every counter weakly not-taken (01)
//   - training lands in upd_pc's slot, not the slot of whatever sits in ID
//     (every training below has a different instruction parked in ID, as in
//     the pipeline)
//   - 2-bit saturating counter: hysteresis, saturation at 00 and 11
//   - upd_valid low or clk_en low trains nothing
//   - 2^IDX_BITS consecutive instructions in an aligned block never share a slot
module tb_branch_predictor;

    localparam IDX_BITS = 4;
    localparam N        = 1 << IDX_BITS;
    localparam [31:0] P = 32'h0000_0400;    // a branch; aligned for any IDX_BITS up to 8
    localparam [31:0] Q = P + 32'd4;        // the instruction in ID while P trains

    localparam BR = 0, JAL = 1, JALR = 2, OTHER = 3;

    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst = 1, clk_en = 1;
    reg        valid = 0, jal = 0, jalr = 0, branch = 0;
    reg [31:0] pc = 0, imm = 0;
    reg        upd_valid = 0, upd_taken = 0;
    reg [31:0] upd_pc = 0;
    wire        pred;
    wire [31:0] target;

    branch_predictor #(.IDX_BITS(IDX_BITS)) dut (
        .clk(clk), .rst(rst), .clk_en(clk_en),
        .valid(valid), .pc(pc), .jal(jal), .jalr(jalr), .branch(branch), .imm(imm),
        .pred_take_branch(pred), .bp_pc(target),
        .upd_valid(upd_valid), .upd_pc(upd_pc), .upd_taken(upd_taken)
    );

    integer errors = 0, checks = 0;
    integer j, k, bad_j, bad_k;

    // put an instruction in ID, decoded the way ctl does it (jalr also raises jal)
    task lookup(input v, input [31:0] at, input integer kind, input [31:0] offset);
        begin
            valid = v; pc = at; imm = offset;
            branch = (kind == BR);
            jal    = (kind == JAL) || (kind == JALR);
            jalr   = (kind == JALR);
            #1;
        end
    endtask

    // exp_target is only compared when a taken prediction is expected
    task expect_pred(input exp_taken, input [31:0] exp_target, input [511:0] name);
        begin
            checks = checks + 1;
            if (pred !== exp_taken || (exp_taken && target !== exp_target)) begin
                errors = errors + 1;
                $display("FAIL %0s", name);
                $display("       pc=%08x  expected taken=%0d target=%08x  got taken=%0d target=%08x",
                         pc, exp_taken, exp_target, pred, target);
            end else
                $display("ok   %0s", name);
        end
    endtask

    // one EX-stage resolution of the branch at `at`, with Q parked in ID
    task train(input [31:0] at, input taken);
        begin
            @(negedge clk);
            lookup(1, Q, BR, 32'd8);
            upd_valid = 1; upd_pc = at; upd_taken = taken;
            @(negedge clk);
            upd_valid = 0;
        end
    endtask

    task do_reset;
        begin
            @(negedge clk); rst = 1;
            @(negedge clk); rst = 0;
        end
    endtask

    initial begin
        do_reset;

        // ---- predictions that need no history ----
        lookup(1, 32'h14, JAL, 32'd16);
        expect_pred(1, 32'h24, "jal: taken, target pc+imm");
        lookup(1, 32'h2000, JAL, -32'd8);
        expect_pred(1, 32'h1ff8, "jal: backward target");
        lookup(1, 32'h18, JALR, 32'd0);
        expect_pred(0, 0, "jalr: not taken (resolved in EX)");
        lookup(1, 32'h1c, OTHER, 32'd7);
        expect_pred(0, 0, "non-branch: not taken");
        lookup(0, 32'h14, JAL, 32'd16);
        expect_pred(0, 0, "bubble (valid=0): not taken");
        lookup(1, P, BR, -32'd12);
        expect_pred(0, 0, "reset: branch weakly not-taken");

        // ---- training reaches upd_pc's slot ----
        train(P, 1);                                            // 01 -> 10
        lookup(1, P, BR, -32'd12);
        expect_pred(1, P - 12, "one taken flips weakly-NT to taken, target pc+imm");
        lookup(1, Q, BR, 32'd8);
        expect_pred(0, 0, "training lands at upd_pc, not at the pc in ID");

        // ---- 2-bit hysteresis and saturation ----
        train(P, 1);                                            // 10 -> 11
        train(P, 0);                                            // 11 -> 10
        lookup(1, P, BR, -32'd12);
        expect_pred(1, P - 12, "strongly taken survives one not-taken");
        train(P, 0);                                            // 10 -> 01
        lookup(1, P, BR, -32'd12);
        expect_pred(0, 0, "second not-taken flips it");
        train(P, 0); train(P, 0); train(P, 0);                  // saturate at 00
        train(P, 1);                                            // 00 -> 01
        lookup(1, P, BR, -32'd12);
        expect_pred(0, 0, "saturates at 00: one taken is not enough");
        train(P, 1);                                            // 01 -> 10
        lookup(1, P, BR, -32'd12);
        expect_pred(1, P - 12, "...and the second taken is");
        train(P, 1); train(P, 1); train(P, 1);                  // saturate at 11
        train(P, 0);                                            // 11 -> 10
        lookup(1, P, BR, -32'd12);
        expect_pred(1, P - 12, "saturates at 11: no wrap to 00");
        lookup(0, P, BR, -32'd12);
        expect_pred(0, 0, "bubble with a trained counter: not taken");

        // ---- nothing trains without upd_valid, or on a disabled edge ----
        do_reset;
        @(negedge clk); upd_valid = 0; upd_pc = P; upd_taken = 1;
        @(negedge clk); @(negedge clk);
        lookup(1, P, BR, -32'd12);
        expect_pred(0, 0, "upd_valid low trains nothing");
        @(negedge clk); clk_en = 0; upd_valid = 1;
        @(negedge clk); @(negedge clk);
        upd_valid = 0; clk_en = 1;
        lookup(1, P, BR, -32'd12);
        expect_pred(0, 0, "clk_en low trains nothing");

        // ---- reset clears trained state ----
        train(P, 1); train(P, 1);
        do_reset;
        lookup(1, P, BR, -32'd12);
        expect_pred(0, 0, "reset clears trained state");

        // ---- N consecutive instructions get N distinct slots: train each one
        //      in turn and make sure no other one moved ----
        bad_j = -1; bad_k = -1;
        for (j = 0; j < N; j = j + 1) begin
            do_reset;
            train(P + 4*j, 1); train(P + 4*j, 1);
            for (k = 0; k < N; k = k + 1) begin
                lookup(1, P + 4*k, BR, 32'd8);
                if (k != j && pred && bad_j < 0) begin bad_j = j; bad_k = k; end
            end
        end
        checks = checks + 1;
        if (bad_j >= 0) begin
            errors = errors + 1;
            $display("FAIL %0d consecutive instructions get %0d distinct slots", N, N);
            $display("       training pc=%08x also moved the counter of pc=%08x",
                     P + 4*bad_j, P + 4*bad_k);
        end else
            $display("ok   %0d consecutive instructions get %0d distinct slots", N, N);

        $display("");
        if (errors == 0) $display("BRANCH PREDICTOR: ALL %0d CHECKS PASSED", checks);
        else             $display("BRANCH PREDICTOR: %0d of %0d checks FAILED", errors, checks);
        $finish;
    end
endmodule
