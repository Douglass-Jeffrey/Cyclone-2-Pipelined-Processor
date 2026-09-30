`include "defines.vh"

module regfile (
    input wire clk,
    input wire rst,
    input wire [4:0] rs1_addr,
    input wire [4:0] rs2_addr,
    input wire [4:0] rd_addr,
    input wire [31:0] rd_data,
    input wire rd_we,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data

);
    reg [31:0] registers [0:31];

    // registers power up as zero so simulation never reads X
    integer i;
    initial for (i = 0; i < 32; i = i + 1) registers[i] = 32'd0;

    //write through bypassing for ID, WB reg collision
    wire wr_hit = rd_we && (rd_addr != 5'd0);

    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : (wr_hit && rd_addr == rs1_addr) ? rd_data : registers[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : (wr_hit && rd_addr == rs2_addr) ? rd_data : registers[rs2_addr];

    always @(posedge clk) begin
        if (rd_we && rd_addr != 5'd0) begin
            registers[rd_addr] <= rd_data;
        end
    end
endmodule