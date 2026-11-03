//tournament branch predictor (BP_TYPE = BP_TOURNAMENT); ports are branch_predictor.v's
`include "defines.vh"
module tournament_bp #(
    parameter IDX_BITS   = `BP_IDX_BITS,    // 2^IDX_BITS pc slots: local histories and choosers
    parameter HIST_BITS  = `BP_HIST_BITS,   // global history bits (gshare side)
    parameter LHIST_BITS = `BP_LHIST_BITS   // bits per slot history (local side)
) (
    input   wire        clk,
    input   wire        rst,
    input   wire        clk_en,

    // lookup: instruction in ID
    input   wire        valid,              // if_id_valid
    input   wire [31:0] pc,
    input   wire        jal,
    input   wire        jalr,
    input   wire        branch,
    input   wire [31:0] imm,
    output  reg         pred_take_branch,
    output  reg  [31:0] bp_pc,
    output  wire [`BP_META_W-1:0] pred_meta,
    input   wire        id_advance,         // the instr in ID moves to EX at this edge

    // update: conditional branch resolving in EX
    input   wire        upd_valid,
    input   wire [31:0] upd_pc,
    input   wire        upd_taken,
    input   wire        upd_mispredict,     // it was predicted wrong, front end redirected
    input   wire [`BP_META_W-1:0] upd_meta  // pred_meta from its own lookup
);
    // gshare_bp.v's and local_bp.v's tables side by side, both trained on every branch, and
    // a 2-bit chooser per pc slot that learns which one to follow for that branch
    localparam GW = IDX_BITS + HIST_BITS;   // gshare index bits

    // gshare side. Speculative as in gshare_bp.v, but shifted with the prediction the front
    // end followed (maybe local's), so it only needs repair when that one was wrong
    reg [HIST_BITS-1:0]  ghist;
    reg [1:0]            g_ctr  [0:(1<<GW)-1];
    // local side, as in local_bp.v
    reg [LHIST_BITS-1:0] lhist  [0:(1<<IDX_BITS)-1];
    reg [1:0]            l_ctr  [0:(1<<LHIST_BITS)-1];
    // chooser: 10/11 follow gshare, 00/01 follow local
    reg [1:0]            choice [0:(1<<IDX_BITS)-1];
    integer i;

    wire [IDX_BITS-1:0]   lk_idx   = pc[IDX_BITS+1:2];
    wire [GW-1:0]         lk_gidx  = pc[GW+1:2] ^ {ghist, {IDX_BITS{1'b0}}};
    wire [LHIST_BITS-1:0] lk_lhist = lhist[lk_idx];
    wire                  g_pred   = g_ctr[lk_gidx][1];
    wire                  l_pred   = l_ctr[lk_lhist][1];

    // meta: both sides' guesses (the chooser trains on them) and each side's lookup state
    localparam M_LH = IDX_BITS, M_GI = M_LH + LHIST_BITS, M_GH = M_GI + GW, M_P = M_GH + HIST_BITS;
    assign pred_meta = {{(`BP_META_W-M_P-2){1'b0}}, g_pred, l_pred, ghist, lk_gidx, lk_lhist, lk_idx};
    wire [IDX_BITS-1:0]   upd_idx   = upd_meta[M_LH-1:0];
    wire [LHIST_BITS-1:0] upd_lhist = upd_meta[M_GI-1:M_LH];
    wire [GW-1:0]         upd_gidx  = upd_meta[M_GH-1:M_GI];
    wire [HIST_BITS-1:0]  upd_ghist = upd_meta[M_P-1:M_GH];
    wire                  upd_l     = upd_meta[M_P];
    wire                  upd_g     = upd_meta[M_P+1];

    function [1:0] sat(input [1:0] c, input up);    // one step of a 2-bit saturating counter
        sat = up ? ((c == 2'b11) ? c : c + 2'd1) : ((c == 2'b00) ? c : c - 2'd1);
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            ghist <= {HIST_BITS{1'b0}};
            for (i = 0; i < (1<<GW); i = i + 1)
                g_ctr[i] <= 2'b01;
            for (i = 0; i < (1<<IDX_BITS); i = i + 1) begin
                lhist[i]  <= {LHIST_BITS{1'b0}};
                choice[i] <= 2'b10;         // start weakly on gshare
            end
            for (i = 0; i < (1<<LHIST_BITS); i = i + 1)
                l_ctr[i] <= 2'b01;
        end
        else if (clk_en) begin
            // never both: a mispredict squashes the instr in ID, so it doesn't advance
            if (upd_valid && upd_mispredict)
                ghist <= {upd_ghist[HIST_BITS-2:0], upd_taken};
            else if (id_advance && valid && branch)
                ghist <= {ghist[HIST_BITS-2:0], pred_take_branch};

            if (upd_valid) begin
                g_ctr[upd_gidx]  <= sat(g_ctr[upd_gidx], upd_taken);
                l_ctr[upd_lhist] <= sat(l_ctr[upd_lhist], upd_taken);
                lhist[upd_idx]   <= {lhist[upd_idx][LHIST_BITS-2:0], upd_taken};
                // when they disagree exactly one was right: step toward it
                if (upd_g != upd_l)
                    choice[upd_idx] <= sat(choice[upd_idx], upd_g == upd_taken);
            end
        end
    end

    // if instr is branch decide based on predictor; defaults first so nothing latches
    always @(*) begin
        pred_take_branch = 1'b0;
        bp_pc            = pc + imm;
        if (valid) begin
            if (branch)
                pred_take_branch = choice[lk_idx][1] ? g_pred : l_pred;
            else if (jal && !jalr)          // ctl sets jal for jalr too
                pred_take_branch = 1'b1;
        end
    end

endmodule
