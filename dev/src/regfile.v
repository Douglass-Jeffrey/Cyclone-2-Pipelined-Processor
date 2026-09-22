`include "defines.vh"

module regfile (
    input wire clk,                 //clock
    input wire rst,                 //reset
    input wire [4:0] rs1_addr,      //source register 1 address
    input wire [4:0] rs2_addr,      //source register 2 address
    input wire [4:0] rd_addr,       //destination register address
    input wire [31:0] rd_data,      //destination register data
    input wire rd_we,               //destination register write enable
    output wire [31:0] rs1_data,    //source register 1 data
    output wire [31:0] rs2_data     //source register 2 data

);
    reg [31:0] registers [0:31];

    // registers power up as zero so simulation never reads X
    integer i;
    initial for (i = 0; i < 32; i = i + 1) registers[i] = 32'd0;

    // Write-through: the write port commits on the clock edge, so a reader in
    // ID during the same cycle would see the OLD value.  That is exactly the
    // case of a consumer three instructions behind its producer (producer in
    // WB, consumer in ID); by the time the consumer reaches EX the producer
    // has left and no forwarding path can catch it.  Bypass it here instead.
    wire wr_hit = rd_we && (rd_addr != 5'd0);

    assign rs1_data = (rs1_addr == 5'd0)                ? 32'd0   :
                      (wr_hit && rd_addr == rs1_addr)   ? rd_data :
                                                          registers[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0)                ? 32'd0   :
                      (wr_hit && rd_addr == rs2_addr)   ? rd_data :
                                                          registers[rs2_addr];

    always @(posedge clk) begin
        if (rd_we && rd_addr != 5'd0) begin
            registers[rd_addr] <= rd_data;
        end
    end
endmodule