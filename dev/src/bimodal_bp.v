`include "defines.vh"
// bimodal predictor: one 2-bit counter per pc slot (BP_TYPE = BP_BIMODAL).
// Ports are branch_predictor.v's, which picks this or another predictor.
module bimodal_bp #(
    parameter IDX_BITS = `BP_IDX_BITS       // table has 2^IDX_BITS counters
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
    //branch = pc+immb
    //jal    = pc+immj

    // 2-bit saturating counters: 00/01 predict not taken, 10/11 predict taken
    reg [1:0] two_bp [0:(1<<IDX_BITS)-1];
    integer i;

    // map via lowest pc bits; meta carries the index so training writes the counter the lookup read
    wire [IDX_BITS-1:0] lk_idx  = pc[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] upd_idx = upd_meta[IDX_BITS-1:0];
    assign pred_meta = {{(`BP_META_W-IDX_BITS){1'b0}}, lk_idx};

    //update predictor fsm on success or mispredict
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < (1<<IDX_BITS); i = i + 1)
                two_bp[i] <= 2'b01;
        end
        else if (clk_en && upd_valid) begin
            if (upd_taken)
                two_bp[upd_idx] <= (two_bp[upd_idx] != 2'b11) ? two_bp[upd_idx] + 2'd1 : 2'b11;
            else
                two_bp[upd_idx] <= (two_bp[upd_idx] != 2'b00) ? two_bp[upd_idx] - 2'd1 : 2'b00;
        end
    end

    // if instr is branch decide based on predictor; defaults first so nothing latches
    always @(*) begin
        pred_take_branch = 1'b0;
        bp_pc            = pc + imm;
        if (valid) begin
            if (branch)
                pred_take_branch = two_bp[lk_idx][1];
            else if (jal && !jalr)          // ctl sets jal for jalr too
                pred_take_branch = 1'b1;
        end
    end

endmodule
