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
module branch_predictor #(
    parameter IDX_BITS = 5                  // table has 2^IDX_BITS counters
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

    // update: conditional branch resolving in EX
    input   wire        upd_valid,
    input   wire [31:0] upd_pc,
    input   wire        upd_taken
);
    //branch = pc+immb
    //jal    = pc+immj

    // 2-bit saturating counters: 00/01 predict not taken, 10/11 predict taken
    reg [1:0] two_bp [0:(1<<IDX_BITS)-1];
    integer i;

    // map via lowest pc bits
    wire [IDX_BITS-1:0] lk_idx  = pc[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] upd_idx = upd_pc[IDX_BITS+1:2];

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
