`include "defines.vh"
/*Two different ways i could do this, predict in the IF stage or predict in the ID stage
*
* OPTION 1
* Predicting in the IF stage means that i could have worst case path of a redirect being true
* and the redirected PC is that of a branch so we also do bp, which is very long crit path.
* the solution to this could be NOT having same cycle redirects. Same cycle redirects being
* when a redirect happens the redirected instruction goes through ID stage in immediate next
* cycle.
*
* So disabling same cycle redirects we would put in a reg for the redirect output and send
* that to if on next cycle. This would mean that we would have to flush IF and ID though
* and would delay the cpu if the critical path speedup doesnt out weigh the extra cycle flush.
*
* OPTION 2
* OTHER option is decoding in ID stage and using the same redirect on same cycle type logic.
* This will probably be FASTER since we arent adding BP onto already longest crit path
* which is id_ex->redirect->pc->(if_id and imem).
*
* Problem with this though is that it still might not meet timing because
* if_id->decode->BP->pc->(if_id and imem) might be longer than the current longest crit path.
* I dont know enough about how the LE's work in fpga to know if adding more pipeline stages
* to shorten crit path allowing increase in clk freq will actually make the CPU faster, but
* I know that it will increase LE usage and possibly introduce more hazards so im going to
* put off lengthening the pipeline for now.
*
* GOING WITH OPTION 2
* Starting with simple 2 bit predictor
* the predictor also handles jal; jalr still resolves in EX (rs1 isn't forwarded in ID)
*/
// Ports every predictor shares, so a new one drops in without touching pipeline.v:
// lookup in ID, id_advance when that instr enters EX (where speculative history
// shifts), update from EX. pred_meta is whatever the lookup needs again at
// training (index, history snapshot); the pipeline carries it in id_ex unchanged.
// TYPE (dev/defines.vh BP_TYPE) picks which predictor this is.
module branch_predictor #(
    parameter TYPE      = `BP_TYPE,
    parameter IDX_BITS  = `BP_IDX_BITS,     // 2^IDX_BITS pc slots
    parameter HIST_BITS = `BP_HIST_BITS,    // global history bits (corr, gshare, tournament)
    parameter LHIST_BITS = `BP_LHIST_BITS   // bits per slot history (local, tournament)
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
    output  wire        pred_take_branch,
    output  wire [31:0] bp_pc,
    output  wire [`BP_META_W-1:0] pred_meta,
    input   wire        id_advance,         // the instr in ID moves to EX at this edge

    // update: conditional branch resolving in EX
    input   wire        upd_valid,
    input   wire [31:0] upd_pc,
    input   wire        upd_taken,
    input   wire        upd_mispredict,     // it was predicted wrong, front end redirected
    input   wire [`BP_META_W-1:0] upd_meta  // pred_meta from its own lookup
);
    generate
        if (TYPE == `BP_BIMODAL) begin : g_bimodal
            bimodal_bp #(.IDX_BITS(IDX_BITS)) u_pred (
                .clk(clk), .rst(rst), .clk_en(clk_en),
                .valid(valid), .pc(pc), .jal(jal), .jalr(jalr), .branch(branch), .imm(imm),
                .pred_take_branch(pred_take_branch), .bp_pc(bp_pc), .pred_meta(pred_meta),
                .id_advance(id_advance), .upd_valid(upd_valid), .upd_pc(upd_pc),
                .upd_taken(upd_taken), .upd_mispredict(upd_mispredict), .upd_meta(upd_meta));
        end else if (TYPE == `BP_CORR) begin : g_corr
            corr_bp #(.IDX_BITS(IDX_BITS), .HIST_BITS(HIST_BITS)) u_pred (
                .clk(clk), .rst(rst), .clk_en(clk_en),
                .valid(valid), .pc(pc), .jal(jal), .jalr(jalr), .branch(branch), .imm(imm),
                .pred_take_branch(pred_take_branch), .bp_pc(bp_pc), .pred_meta(pred_meta),
                .id_advance(id_advance), .upd_valid(upd_valid), .upd_pc(upd_pc),
                .upd_taken(upd_taken), .upd_mispredict(upd_mispredict), .upd_meta(upd_meta));
        end else if (TYPE == `BP_GSHARE) begin : g_gshare
            gshare_bp #(.IDX_BITS(IDX_BITS), .HIST_BITS(HIST_BITS)) u_pred (
                .clk(clk), .rst(rst), .clk_en(clk_en),
                .valid(valid), .pc(pc), .jal(jal), .jalr(jalr), .branch(branch), .imm(imm),
                .pred_take_branch(pred_take_branch), .bp_pc(bp_pc), .pred_meta(pred_meta),
                .id_advance(id_advance), .upd_valid(upd_valid), .upd_pc(upd_pc),
                .upd_taken(upd_taken), .upd_mispredict(upd_mispredict), .upd_meta(upd_meta));
        end else if (TYPE == `BP_LOCAL) begin : g_local
            local_bp #(.IDX_BITS(IDX_BITS), .LHIST_BITS(LHIST_BITS)) u_pred (
                .clk(clk), .rst(rst), .clk_en(clk_en),
                .valid(valid), .pc(pc), .jal(jal), .jalr(jalr), .branch(branch), .imm(imm),
                .pred_take_branch(pred_take_branch), .bp_pc(bp_pc), .pred_meta(pred_meta),
                .id_advance(id_advance), .upd_valid(upd_valid), .upd_pc(upd_pc),
                .upd_taken(upd_taken), .upd_mispredict(upd_mispredict), .upd_meta(upd_meta));
        end else if (TYPE == `BP_TOURNAMENT) begin : g_tournament
            tournament_bp #(.IDX_BITS(IDX_BITS), .HIST_BITS(HIST_BITS), .LHIST_BITS(LHIST_BITS)) u_pred (
                .clk(clk), .rst(rst), .clk_en(clk_en),
                .valid(valid), .pc(pc), .jal(jal), .jalr(jalr), .branch(branch), .imm(imm),
                .pred_take_branch(pred_take_branch), .bp_pc(bp_pc), .pred_meta(pred_meta),
                .id_advance(id_advance), .upd_valid(upd_valid), .upd_pc(upd_pc),
                .upd_taken(upd_taken), .upd_mispredict(upd_mispredict), .upd_meta(upd_meta));
        end else begin : g_unknown
            BP_TYPE_names_no_predictor u_err ();    // no such module: an unknown TYPE fails to build
        end
    endgenerate

endmodule
