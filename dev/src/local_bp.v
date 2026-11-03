//local branch predictor (BP_TYPE = BP_LOCAL); ports are branch_predictor.v's
`include "defines.vh"
module local_bp #(
    parameter IDX_BITS   = `BP_IDX_BITS,    // 2^IDX_BITS pc slots, each with its own history
    parameter LHIST_BITS = `BP_LHIST_BITS   // bits per slot history; 2^LHIST_BITS counters
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
    // two levels: the pc picks a slot's history (that branch's own last outcomes), and the
    // history picks a counter. Loops with a fixed trip count become a pattern it learns.

    // level 1: shifted at training, like corr's history
    reg [LHIST_BITS-1:0] lhist [0:(1<<IDX_BITS)-1];
    // level 2: 2-bit counters indexed by history alone, so every slot shares them
    reg [1:0] two_bp_counter [0:(1<<LHIST_BITS)-1];
    integer i;

    wire [IDX_BITS-1:0]   lk_idx   = pc[IDX_BITS+1:2];
    wire [LHIST_BITS-1:0] lk_hist  = lhist[lk_idx];
    // meta carries {history, slot} so training writes the counter the lookup read
    wire [IDX_BITS-1:0]   upd_idx  = upd_meta[IDX_BITS-1:0];
    wire [LHIST_BITS-1:0] upd_hist = upd_meta[LHIST_BITS+IDX_BITS-1:IDX_BITS];
    assign pred_meta = {{(`BP_META_W-LHIST_BITS-IDX_BITS){1'b0}}, lk_hist, lk_idx};

    function [1:0] sat(input [1:0] c, input up);    // one step of a 2-bit saturating counter
        sat = up ? ((c == 2'b11) ? c : c + 2'd1) : ((c == 2'b00) ? c : c - 2'd1);
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < (1<<IDX_BITS); i = i + 1)
                lhist[i] <= {LHIST_BITS{1'b0}};
            for (i = 0; i < (1<<LHIST_BITS); i = i + 1)
                two_bp_counter[i] <= 2'b01;
        end
        else if (clk_en && upd_valid) begin
            lhist[upd_idx]           <= {lhist[upd_idx][LHIST_BITS-2:0], upd_taken};
            two_bp_counter[upd_hist] <= sat(two_bp_counter[upd_hist], upd_taken);
        end
    end

    // if instr is branch decide based on predictor; defaults first so nothing latches
    always @(*) begin
        pred_take_branch = 1'b0;
        bp_pc            = pc + imm;
        if (valid) begin
            if (branch)
                pred_take_branch = two_bp_counter[lk_hist][1];
            else if (jal && !jalr)          // ctl sets jal for jalr too
                pred_take_branch = 1'b1;
        end
    end

endmodule
