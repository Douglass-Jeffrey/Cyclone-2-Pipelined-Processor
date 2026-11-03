//correlating branch predictor (BP_TYPE = BP_CORR); ports are branch_predictor.v's
`include "defines.vh"
module corr_bp #(
    parameter IDX_BITS = `BP_IDX_BITS,     // 2^IDX_BITS pc slots
    parameter HIST_BITS= `BP_HIST_BITS     // 2^HIST_BITS counters per slot
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
    //correlating, keep a history of tha last m recent branches, storing a 2 bit predictor
    // for each of the 2^m possible histories, for each idx bits

    reg [HIST_BITS-1:0] hist;
    // 2-bit saturating counters: 00/01 predict not taken, 10/11 predict taken
    reg [1:0] two_bp_counter [0:(1<<HIST_BITS)-1][0:(1<<IDX_BITS)-1];
    integer i, j;

    // map via lowest pc bits; meta carries {hist, index} so training writes the counter the lookup read
    wire [IDX_BITS-1:0] lk_idx  = pc[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] upd_idx = upd_meta[IDX_BITS-1:0];
    wire [HIST_BITS-1:0] upd_hist = upd_meta[HIST_BITS+IDX_BITS-1:IDX_BITS];
    assign pred_meta = {{(`BP_META_W-HIST_BITS-IDX_BITS){1'b0}}, hist, lk_idx};

    //update predictor fsm on success or mispredict
    always @(posedge clk) begin
        if (rst) begin
            //start hist as all 0. 
            hist <= {HIST_BITS{1'b0}};
            for (i = 0; i < (1<<HIST_BITS); i = i + 1) begin
                for (j = 0; j < (1<<IDX_BITS); j = j + 1) begin
                    two_bp_counter[i][j] <= 2'b01;
                end
            end
        end
        else if (clk_en && upd_valid) begin
            hist <= {hist[HIST_BITS-2:0], upd_taken};
            if (upd_taken)
                two_bp_counter[upd_hist][upd_idx] <= (two_bp_counter[upd_hist][upd_idx] != 2'b11) ? two_bp_counter[upd_hist][upd_idx] + 2'd1 : 2'b11;
            else
                two_bp_counter[upd_hist][upd_idx] <= (two_bp_counter[upd_hist][upd_idx] != 2'b00) ? two_bp_counter[upd_hist][upd_idx] - 2'd1 : 2'b00;
        end
    end

    // if instr is branch decide based on predictor; defaults first so nothing latches
    always @(*) begin
        pred_take_branch = 1'b0;
        bp_pc            = pc + imm;
        if (valid) begin
            if (branch)
                pred_take_branch = two_bp_counter[hist][lk_idx][1];
            else if (jal && !jalr)          // ctl sets jal for jalr too
                pred_take_branch = 1'b1;
        end
    end

endmodule