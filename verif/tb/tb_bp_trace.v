`timescale 1ns/1ps
`include "defines.vh"

// Replays trace.hex (written by bp_model.unit_trace for this TYPE and these
// sizes) through dev/src/branch_predictor.v, driving its ports the way the
// pipeline does, and checks every branch's prediction against the model's.
// Run by verif/run_unit_tests.py once per predictor.
//
// trace.hex: the correct-path instructions in program order, one word each,
// ending in ffffffff:
//   [31:30] kind (0 conditional branch, 1 jal, 2 other)   [29] taken
//   [28] the model's prediction   [27:26] cycles held in ID first   [15:0] pc
//
// Each cycle the instr in ID either advances to EX (id_advance) or is held,
// and the branch in EX (if any) trains.  A mispredict squashes the instr
// behind it: a wrong-path branch sits in ID for that cycle without advancing.
// Every 5th edge has clk_en low, which must change nothing.
module tb_bp_trace;

    parameter TYPE       = `BP_TYPE;
    parameter IDX_BITS   = 4;
    parameter HIST_BITS  = 3;
    parameter LHIST_BITS = 3;
    localparam [31:0] WRONG_PC = 32'h0000_0ff0;    // wrong-path branch, squashed in ID

    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst = 1, clk_en = 1;
    reg        valid = 0, jal = 0, jalr = 0, branch = 0;
    reg [31:0] pc = 0, imm = 8;
    reg        upd_valid = 0, upd_taken = 0, upd_mispredict = 0, id_advance = 0;
    reg [31:0] upd_pc = 0;
    reg  [`BP_META_W-1:0] upd_meta = 0;
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

    reg [31:0] tr [0:262143];
    reg [31:0] w;
    integer i = 0, held = 0, cyc = 0, branches = 0, errors = 0;

    // the instr in EX: a conditional branch's outcome, prediction and meta
    reg                  ex_br = 0, ex_taken = 0, ex_pred = 0;
    reg [31:0]           ex_pc = 0;
    reg [`BP_META_W-1:0] ex_meta = 0;
    reg                  squash, id_pred;
    reg [`BP_META_W-1:0] id_meta;

    initial begin
        $readmemh("trace.hex", tr);
        @(negedge clk); @(negedge clk); rst = 0;

        while (tr[i] !== 32'hffff_ffff && errors == 0) begin
            @(negedge clk);
            clk_en = (cyc % 5) != 4;
            cyc = cyc + 1;

            // EX: the branch there trains (a bubble trains nothing)
            upd_valid      = ex_br;
            upd_pc         = ex_pc;
            upd_taken      = ex_taken;
            upd_meta       = ex_meta;
            upd_mispredict = ex_br && (ex_pred != ex_taken);
            squash         = upd_mispredict;

            // ID: the next correct-path instr, unless the branch in EX squashes it
            w = tr[i];
            valid  = 1;
            pc     = squash ? WRONG_PC : {16'd0, w[15:0]};
            branch = squash || (w[31:30] == 2'd0);
            jal    = !squash && (w[31:30] == 2'd1);
            id_advance = !squash && (held >= w[27:26]);
            #1;
            id_pred = pred;                 // what id_ex samples at the edge
            id_meta = meta;

            if (id_advance && branch && clk_en) begin
                branches = branches + 1;
                if (pred !== w[28]) begin
                    errors = errors + 1;
                    $display("FAIL branch %0d (trace word %0d, pc %08x): predicted %0d, the model %0d",
                             branches, i, pc, pred, w[28]);
                end
            end

            @(posedge clk); #1;
            if (clk_en) begin
                // EX takes what advanced, or a bubble
                ex_br    = id_advance && branch;
                ex_pc    = pc;
                ex_taken = w[29];
                ex_pred  = id_pred;
                ex_meta  = id_meta;
                if (id_advance) begin i = i + 1; held = 0; end
                else if (!squash) held = held + 1;
            end
        end

        $display("");
        if (errors == 0) $display("BP TRACE (TYPE %0d): ALL %0d PREDICTIONS MATCH THE MODEL, PASSED", TYPE, branches);
        else             $display("BP TRACE (TYPE %0d): prediction %0d differs from the model", TYPE, branches);
        $finish;
    end
endmodule
