`include "defines.vh"

//for non load RAW dependencies
// before alu ex, check that values for rs1, rs2 arent in flight in later pipeline stage
// if they are, use them instead of reg file's copy.
// MEM takes precedence over WB since MEM is more up to date copy of the register data
module forwarding_unit (
    input  wire [4:0] ex_rs1_addr,
    input  wire [4:0] ex_rs2_addr,

    input  wire       mem_valid,
    input  wire       mem_reg_write,
    input  wire [4:0] mem_rd_addr,

    input  wire       wb_valid,
    input  wire       wb_reg_write,
    input  wire [4:0] wb_rd_addr,

    output reg  [1:0] fwd_a,
    output reg  [1:0] fwd_b
);
    wire mem_writes = mem_valid && mem_reg_write && (mem_rd_addr != 5'd0);
    wire wb_writes  = wb_valid  && wb_reg_write  && (wb_rd_addr  != 5'd0);

    always @(*) begin
        if      (mem_writes && mem_rd_addr == ex_rs1_addr) fwd_a = `FWD_MEM;
        else if (wb_writes  && wb_rd_addr  == ex_rs1_addr) fwd_a = `FWD_WB;
        else                                               fwd_a = `FWD_NONE;

        if      (mem_writes && mem_rd_addr == ex_rs2_addr) fwd_b = `FWD_MEM;
        else if (wb_writes  && wb_rd_addr  == ex_rs2_addr) fwd_b = `FWD_WB;
        else                                               fwd_b = `FWD_NONE;
    end
endmodule
