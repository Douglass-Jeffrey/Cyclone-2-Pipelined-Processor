//gshare branch predictor (BP_TYPE = BP_GSHARE); ports are branch_predictor.v's
`include "defines.vh"
module gshare_bp #(
    parameter IDX_BITS  = `BP_IDX_BITS,     // 2^(IDX_BITS+HIST_BITS) counters, as many as corr has
    parameter HIST_BITS = `BP_HIST_BITS     // global history bits
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
    // gshare: one table indexed by pc XOR global history, so every index bit is a pc bit
    // AND a history bit, where corr splits its index between the two
    localparam W = IDX_BITS + HIST_BITS;    // index bits

    // speculative: a branch shifts its prediction in as it enters EX, so the branch right
    // behind it already sees it; a mispredict puts back the lookup's history + the real outcome
    reg [HIST_BITS-1:0] hist;
    // 2-bit saturating counters: 00/01 predict not taken, 10/11 predict taken
    reg [1:0] two_bp_counter [0:(1<<W)-1];
    integer i;

    // history XORs the TOP bits: only branches 2^IDX_BITS words apart can share a counter
    wire [W-1:0]         lk_idx   = pc[W+1:2] ^ {hist, {IDX_BITS{1'b0}}};
    // meta carries {hist, index}: the index to train, the history to repair from
    wire [W-1:0]         upd_idx  = upd_meta[W-1:0];
    wire [HIST_BITS-1:0] upd_hist = upd_meta[W+HIST_BITS-1:W];
    assign pred_meta = {{(`BP_META_W-W-HIST_BITS){1'b0}}, hist, lk_idx};

    function [1:0] sat(input [1:0] c, input up);    // one step of a 2-bit saturating counter
        sat = up ? ((c == 2'b11) ? c : c + 2'd1) : ((c == 2'b00) ? c : c - 2'd1);
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            hist <= {HIST_BITS{1'b0}};
            for (i = 0; i < (1<<W); i = i + 1)
                two_bp_counter[i] <= 2'b01;
        end
        else if (clk_en) begin
            // never both: a mispredict squashes the instr in ID, so it doesn't advance
            if (upd_valid && upd_mispredict)
                hist <= {upd_hist[HIST_BITS-2:0], upd_taken};
            else if (id_advance && valid && branch)
                hist <= {hist[HIST_BITS-2:0], pred_take_branch};

            if (upd_valid)
                two_bp_counter[upd_idx] <= sat(two_bp_counter[upd_idx], upd_taken);
        end
    end

    // if instr is branch decide based on predictor; defaults first so nothing latches
    always @(*) begin
        pred_take_branch = 1'b0;
        bp_pc            = pc + imm;
        if (valid) begin
            if (branch)
                pred_take_branch = two_bp_counter[lk_idx][1];
            else if (jal && !jalr)          // ctl sets jal for jalr too
                pred_take_branch = 1'b1;
        end
    end

endmodule
