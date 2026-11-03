`timescale 1ns/1ps
`include "defines.vh"

// Unit test for dev/src/branch_predictor.v, run by verif/run_unit_tests.py once
// per predictor TYPE (iverilog -P), whichever one BP_TYPE builds.  Directed
// checks, each naming one rule; tb_bp_trace.v compares every prediction of a
// long random stream with bp_model.py instead.
//
// Every predictor:
//   - jal predicted taken to pc+imm; jalr, non-branches and bubbles not taken
//   - reset leaves every counter weakly not-taken (01)
// Every one but the tournament (whose chooser couples its two sides):
//   - training lands in the counter the branch's own lookup reported (pred_meta,
//     handed back as upd_meta), not the one of whatever sits in ID (every
//     training below has a different instruction parked in ID, as in the pipeline)
//   - 2-bit saturating counter: hysteresis, saturation at 00 and 11
//   - upd_valid low or clk_en low trains nothing and moves no history
//   - reset clears the histories to 0
//   - bimodal, corr, gshare: 2^IDX_BITS consecutive instructions never share a counter
// These run with the history at 0: train() puts it back after each branch (the
// global history through filler branch R in its own slot, a local slot's own
// history by shifting the taken back out).
//
// BP_CORR and BP_GSHARE: each of the 2^HIST_BITS histories picks its own
// counter, and training uses the history its lookup saw.  BP_GSHARE, BP_LOCAL
// and BP_TOURNAMENT have their own sections below.
module tb_branch_predictor;

    parameter TYPE = `BP_TYPE;
    localparam IDX_BITS   = 4;
    localparam HIST_BITS  = 3;
    localparam LHIST_BITS = 3;
    localparam N  = 1 << IDX_BITS;
    localparam NH = 1 << HIST_BITS;
    localparam GLOBAL = (TYPE == `BP_CORR) || (TYPE == `BP_GSHARE);
    localparam [31:0] P = 32'h0000_0400;    // a branch; aligned for any IDX_BITS up to 8
    localparam [31:0] Q = P + 32'd4;        // the instruction in ID while a branch trains
    localparam [31:0] R = P + 32'd8;        // filler branch whose outcomes set the history
    localparam [31:0] X = P + 32'd12;       // gshare: a branch whose prediction is in flight
    localparam [31:0] S = P + 32'd16;       // local, tournament: other slots
    localparam [31:0] U = P + 32'd20;
    localparam [31:0] ALIAS = P + 4*N;      // P's pc slot, 2^IDX_BITS words on
    localparam [31:0] Z = P + 32'h110;      // tournament: S's slot, gshare index 0x44

    localparam BR = 0, JAL = 1, JALR = 2, OTHER = 3;

    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst = 1, clk_en = 1;
    reg        valid = 0, jal = 0, jalr = 0, branch = 0;
    reg [31:0] pc = 0, imm = 0;
    reg        upd_valid = 0, upd_taken = 0, upd_mispredict = 0, id_advance = 0;
    reg [31:0] upd_pc = 0;
    reg  [`BP_META_W-1:0] upd_meta = 0, p_meta, x_meta;
    reg        p_pred;
    wire [`BP_META_W-1:0] meta;
    wire        pred;
    wire [31:0] target;

    branch_predictor #(.TYPE(TYPE), .IDX_BITS(IDX_BITS), .HIST_BITS(HIST_BITS),
                       .LHIST_BITS(LHIST_BITS)) dut (
        .clk(clk), .rst(rst), .clk_en(clk_en),
        .valid(valid), .pc(pc), .jal(jal), .jalr(jalr), .branch(branch), .imm(imm),
        .pred_take_branch(pred), .bp_pc(target), .pred_meta(meta), .id_advance(id_advance),
        .upd_valid(upd_valid), .upd_pc(upd_pc), .upd_taken(upd_taken),
        .upd_mispredict(upd_mispredict), .upd_meta(upd_meta)
    );

    integer errors = 0, checks = 0;
    integer j, k, b, b2, bad_j, bad_k;

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

    task expect_true(input ok, input [511:0] name);
        begin
            checks = checks + 1;
            if (!ok) begin errors = errors + 1; $display("FAIL %0s", name); end
            else     $display("ok   %0s", name);
        end
    endtask

    // the branch in EX trains from meta m (Q parked in ID); a mispredict if
    // `pred_was` differs from the outcome
    task train_from(input [31:0] at, input taken, input [`BP_META_W-1:0] m, input pred_was);
        begin
            @(negedge clk);
            lookup(1, Q, BR, 32'd8);
            upd_valid = 1; upd_pc = at; upd_taken = taken; upd_meta = m;
            upd_mispredict = (pred_was != taken);
            @(negedge clk);
            upd_valid = 0; upd_mispredict = 0;
        end
    endtask

    // the branch at `at` as the pipeline handles it: looked up in ID and moved
    // to EX (its meta and prediction kept, as id_ex does), then resolved there
    task resolve(input [31:0] at, input taken);
        begin
            @(negedge clk);
            lookup(1, at, BR, 32'd8);
            p_meta = meta; p_pred = pred;
            id_advance = 1;
            @(negedge clk);
            id_advance = 0;
            lookup(1, Q, BR, 32'd8);
            upd_valid = 1; upd_pc = at; upd_taken = taken; upd_meta = p_meta;
            upd_mispredict = (p_pred != taken);
            @(negedge clk);
            upd_valid = 0; upd_mispredict = 0;
        end
    endtask

    // make the last HIST_BITS outcomes h (oldest in the top bit) by resolving R
    task set_hist(input [HIST_BITS-1:0] h);
        begin
            for (b = HIST_BITS - 1; b >= 0; b = b - 1)
                resolve(R, h[b]);
        end
    endtask

    // resolve the branch at `at` from history 0, then put the history back to 0:
    // local shifts a taken back out of the slot's own history (training only
    // counters whose history has a 1 in it), the rest clear the global one
    task train(input [31:0] at, input taken);
        begin
            resolve(at, taken);
            if (TYPE == `BP_LOCAL) begin
                if (taken)
                    for (b2 = 0; b2 < LHIST_BITS; b2 = b2 + 1)
                        resolve(at, 0);
            end else
                set_hist(0);
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

        if (TYPE != `BP_TOURNAMENT) begin
            // ---- training reaches its own lookup's counter ----
            train(P, 1);                                        // 01 -> 10
            lookup(1, P, BR, -32'd12);
            expect_pred(1, P - 12, "one taken flips weakly-NT to taken, target pc+imm");
            if (TYPE != `BP_LOCAL) begin                        // local: Q reads the same counter
                lookup(1, Q, BR, 32'd8);
                expect_pred(0, 0, "training lands in its own lookup's slot, not the pc in ID's");
            end

            // ---- 2-bit hysteresis and saturation ----
            train(P, 1);                                        // 10 -> 11
            train(P, 0);                                        // 11 -> 10
            lookup(1, P, BR, -32'd12);
            expect_pred(1, P - 12, "strongly taken survives one not-taken");
            train(P, 0);                                        // 10 -> 01
            lookup(1, P, BR, -32'd12);
            expect_pred(0, 0, "second not-taken flips it");
            train(P, 0); train(P, 0); train(P, 0);              // saturate at 00
            train(P, 1);                                        // 00 -> 01
            lookup(1, P, BR, -32'd12);
            expect_pred(0, 0, "saturates at 00: one taken is not enough");
            train(P, 1);                                        // 01 -> 10
            lookup(1, P, BR, -32'd12);
            expect_pred(1, P - 12, "...and the second taken is");
            train(P, 1); train(P, 1); train(P, 1);              // saturate at 11
            train(P, 0);                                        // 11 -> 10
            lookup(1, P, BR, -32'd12);
            expect_pred(1, P - 12, "saturates at 11: no wrap to 00");
            lookup(0, P, BR, -32'd12);
            expect_pred(0, 0, "bubble with a trained counter: not taken");

            // ---- nothing trains or moves history without upd_valid, or on a
            //      disabled edge: P is weakly taken (at global history all-ones,
            //      or local history 0), so a not-taken update that leaks either
            //      trains it back to not-taken or moves the history ----
            do_reset;
            if (TYPE == `BP_LOCAL)
                train(P, 1);                                    // counter 0: 01 -> 10
            else begin
                set_hist({HIST_BITS{1'b1}});
                resolve(P, 1);                                  // 01 -> 10, history stays all-ones
            end
            lookup(1, P, BR, -32'd12); upd_meta = meta;
            expect_pred(1, P - 12, "(setup) P weakly taken");
            @(negedge clk); upd_valid = 0; upd_pc = P; upd_taken = 0;
            @(negedge clk); @(negedge clk);
            lookup(1, P, BR, -32'd12);
            expect_pred(1, P - 12, "upd_valid low trains nothing and moves no history");
            @(negedge clk); clk_en = 0; upd_valid = 1; upd_mispredict = 1; id_advance = 1;
            @(negedge clk); @(negedge clk);
            upd_valid = 0; upd_mispredict = 0; id_advance = 0; clk_en = 1;
            lookup(1, P, BR, -32'd12);
            expect_pred(1, P - 12, "clk_en low trains nothing and moves no history");

            // ---- reset clears trained state and history ----
            do_reset;
            train(P, 1); train(P, 1);
            if (TYPE == `BP_LOCAL) resolve(P, 1);               // P's own history 001
            else set_hist({HIST_BITS{1'b1}});
            do_reset;
            lookup(1, P, BR, -32'd12);
            expect_pred(0, 0, "reset clears trained state");
            train(P, 1);                                        // trains P at the reset history
            lookup(1, P, BR, -32'd12);
            expect_pred(1, P - 12, "reset clears the history to 0");
        end

        if (TYPE != `BP_TOURNAMENT && TYPE != `BP_LOCAL) begin
            // ---- N consecutive instructions get N distinct counters: train each
            //      one in turn and make sure no other one moved ----
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
        end

        if (GLOBAL) begin
            // ---- each history picks its own counter: train P at history j
            //      only, then it must predict taken at j and at no other ----
            bad_j = -1; bad_k = -1;
            for (j = 0; j < NH; j = j + 1) begin
                do_reset;
                set_hist(j); resolve(P, 1);
                set_hist(j); resolve(P, 1);                     // P's counter at j -> 11
                for (k = 0; k < NH; k = k + 1) begin
                    set_hist(k);
                    lookup(1, P, BR, 32'd8);
                    if (pred != (k == j) && bad_j < 0) begin bad_j = j; bad_k = k; end
                end
            end
            checks = checks + 1;
            if (bad_j >= 0) begin
                errors = errors + 1;
                $display("FAIL the %0d histories (last %0d outcomes) pick %0d distinct counters",
                         NH, HIST_BITS, NH);
                $display("       P trained at history %b; at history %b it predicts taken=%0d",
                         bad_j[HIST_BITS-1:0], bad_k[HIST_BITS-1:0], bad_k == bad_j ? 0 : 1);
            end else
                $display("ok   the %0d histories (last %0d outcomes) pick %0d distinct counters",
                         NH, HIST_BITS, NH);

            // ---- training uses the history its lookup saw: P looks up at
            //      history 0, then R resolves taken before P trains ----
            do_reset;
            @(negedge clk);
            lookup(1, P, BR, 32'd8);
            x_meta = meta;
            resolve(R, 1);                                      // history now ..001
            train_from(P, 1, x_meta, 0);
            set_hist(0);
            lookup(1, P, BR, 32'd8);
            expect_pred(1, P + 8, "a branch resolved in between: training uses its lookup's history");
            set_hist(1);
            lookup(1, P, BR, 32'd8);
            expect_pred(0, 0, "...not the history when it trains");
        end

        if (TYPE == `BP_GSHARE) begin
            // ---- pc XOR history, the history in the TOP index bits: ALIAS
            //      (2^IDX_BITS words past P) at history 001 reads P's counter at
            //      000; Q (the next word) at 001 does not, as it would if the
            //      history went into the low bits ----
            do_reset;
            train(P, 1); train(P, 1);                           // P at 000 -> 11
            lookup(1, ALIAS, BR, 32'd8);
            expect_pred(0, 0, "gshare: ALIAS at history 000 has its own counter");
            set_hist(1);
            lookup(1, ALIAS, BR, 32'd8);
            expect_pred(1, ALIAS + 8, "gshare: ALIAS at history 001 shares P's at 000 (pc ^ history)");
            lookup(1, Q, BR, 32'd8);
            expect_pred(0, 0, "gshare: Q at history 001 does not (history XORs the top index bits)");

            // ---- the history is speculative: X, predicted taken, shifts its 1
            //      in as it enters EX, so P right behind it sees history 001
            //      (P is taken at 001 and 010 only) ----
            do_reset;
            train(X, 1); train(X, 1);                           // X at 000 -> 11
            set_hist(1); resolve(P, 1); set_hist(1); resolve(P, 1);
            set_hist(2); resolve(P, 1); set_hist(2); resolve(P, 1);
            set_hist(0);
            @(negedge clk);
            lookup(1, X, BR, 32'd8); x_meta = meta;
            expect_pred(1, X + 8, "(setup) gshare: X predicted taken at history 000");
            id_advance = 1;
            @(negedge clk);                                     // X enters EX
            id_advance = 0;
            lookup(1, P, BR, 32'd8);
            expect_pred(1, P + 8, "gshare: X's prediction is in the history before X resolves");
            upd_valid = 1; upd_pc = X; upd_taken = 1; upd_mispredict = 0; upd_meta = x_meta;
            @(negedge clk);
            upd_valid = 0;
            lookup(1, P, BR, 32'd8);
            expect_pred(1, P + 8, "gshare: ...and a right prediction is not shifted in again");

            // ---- a mispredict repairs it: X predicted taken resolves not
            //      taken, so the history is X's lookup history plus a 0 (000):
            //      not the 001 it shifted in, nor 001 shifted again (010) ----
            set_hist(0);
            @(negedge clk);
            lookup(1, X, BR, 32'd8); x_meta = meta;
            id_advance = 1;
            @(negedge clk);
            id_advance = 0;
            lookup(1, Q, BR, 32'd8);                            // wrong path, squashed
            upd_valid = 1; upd_pc = X; upd_taken = 0; upd_mispredict = 1; upd_meta = x_meta;
            @(negedge clk);
            upd_valid = 0; upd_mispredict = 0;
            lookup(1, P, BR, 32'd8);
            expect_pred(0, 0, "gshare: a mispredict puts back the lookup's history + the real outcome");

            // ---- only a conditional branch moving to EX shifts: not one held
            //      in ID, not a jal, not on a disabled edge (X still predicts taken) ----
            @(negedge clk);
            lookup(1, X, BR, 32'd8);
            @(negedge clk); @(negedge clk);
            lookup(1, P, BR, 32'd8);
            expect_pred(0, 0, "gshare: a branch held in ID shifts nothing");
            @(negedge clk);
            lookup(1, X, JAL, 32'd8); id_advance = 1;
            @(negedge clk);
            id_advance = 0;
            lookup(1, P, BR, 32'd8);
            expect_pred(0, 0, "gshare: a jal moving to EX shifts nothing");
            @(negedge clk);
            lookup(1, X, BR, 32'd8); id_advance = 1; clk_en = 0;
            @(negedge clk); @(negedge clk);
            id_advance = 0; clk_en = 1;
            lookup(1, P, BR, 32'd8);
            expect_pred(0, 0, "gshare: nor does a branch on a disabled edge");
        end

        if (TYPE == `BP_LOCAL) begin
            // ---- P's own last outcomes pick its counter, so it learns
            //      T,N,T,N, which a single counter never predicts ----
            do_reset;
            for (j = 0; j < 8; j = j + 1) resolve(P, ~j[0]);
            bad_j = -1;
            for (j = 8; j < 16; j = j + 1) begin
                lookup(1, P, BR, 32'd8);
                if (pred !== !j[0] && bad_j < 0) bad_j = j;
                resolve(P, ~j[0]);
            end
            expect_true(bad_j < 0, "local: P learns T,N,T,N from its own history");

            // ---- each slot has its own history: P goes N,N then T x5 (history
            //      111, counter 11; counter 000 back at 01); S, never resolved,
            //      is still at 000 ----
            do_reset;
            resolve(P, 0); resolve(P, 0);
            for (j = 0; j < 5; j = j + 1) resolve(P, 1);
            lookup(1, P, BR, 32'd8);
            expect_pred(1, P + 8, "(setup) local: P taken at history 111");
            lookup(1, S, BR, 32'd8);
            expect_pred(0, 0, "local: P's outcomes don't move another slot's history");

            // ---- the counters are shared: three takens bring S to 111, where
            //      it reads the counter P trained ----
            resolve(S, 1); resolve(S, 1); resolve(S, 1);
            lookup(1, S, BR, 32'd8);
            expect_pred(1, S + 8, "local: slots share the counters (S at 111 reads P's)");

            // ---- training writes the counter its lookup's history picked: P
            //      looks up at 000, ALIAS (P's slot) resolves taken (slot -> 001),
            //      then P trains taken: counter 000 (read by U), not 001 ----
            do_reset;
            resolve(S, 0);                                      // counter 000: 01 -> 00
            @(negedge clk);
            lookup(1, P, BR, 32'd8);
            x_meta = meta;
            resolve(ALIAS, 1);                                  // counter 000: 00 -> 01
            train_from(P, 1, x_meta, 0);                        // counter 000: 01 -> 10
            lookup(1, U, BR, 32'd8);
            expect_pred(1, U + 8, "local: training uses its lookup's history, not the slot's at training");
        end

        if (TYPE == `BP_TOURNAMENT) begin
            // ---- the chooser starts on gshare. S's taken trains local's
            //      counter 000, so P (local history 000) gets taken from local and
            //      not-taken from gshare, and follows gshare ----
            do_reset;
            resolve(S, 1);
            lookup(1, P, BR, 32'd8);
            expect_pred(0, 0, "tournament: starts on gshare (P: local taken, gshare not)");

            // ---- P was taken: local right, gshare wrong, so P's chooser steps
            //      to local. S's second taken trains local's 001, P's history now;
            //      they disagree the same way again and P follows local ----
            resolve(P, 1);
            resolve(S, 1);
            lookup(1, P, BR, 32'd8);
            expect_pred(1, P + 8, "tournament: after local was right and gshare wrong, P follows local");

            // ---- the global history takes the prediction followed: P (local
            //      taken, gshare not) moves to EX at history 111, leaving 111.
            //      Z follows gshare, taken at 111 and not at 110 ----
            @(negedge clk);
            lookup(1, P, BR, 32'd8);
            id_advance = 1;
            @(negedge clk);
            id_advance = 0;
            lookup(1, Z, BR, 32'd8);
            expect_pred(1, Z + 8, "tournament: global history shifts the followed prediction, not gshare's");
        end

        $display("");
        if (errors == 0) $display("BRANCH PREDICTOR (TYPE %0d): ALL %0d CHECKS PASSED", TYPE, checks);
        else             $display("BRANCH PREDICTOR (TYPE %0d): %0d of %0d checks FAILED", TYPE, errors, checks);
        $finish;
    end
endmodule
