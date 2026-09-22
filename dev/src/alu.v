`include "defines.vh"

module alu (
    input wire [31:0] a,        // first operand
    input wire [31:0] b,        // second operand
    input wire [3:0] alu_op,    // operation selector
    output reg [31:0] result,   // operation result
    output wire zero_flag       // zero flag
);
    wire [4:0] shamt = b[4:0];   // only low 5 bits
    
    assign zero_flag = (result == 32'd0) ? 1'b1 : 1'b0;
    always @(*) begin
        case (alu_op)
            `ALU_ADD:  result = a + b;
            `ALU_SUB:  result = a - b;
            `ALU_AND:  result = a & b;
            `ALU_OR:   result = a | b;
            `ALU_XOR:  result = a ^ b;
            `ALU_SLL:  result = a << shamt;
            `ALU_SRL:  result = a >> shamt;
            `ALU_SRA:  result = $signed(a) >>> shamt;
            `ALU_SLT:  result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            `ALU_SLTU: result = (a < b) ? 32'd1 : 32'd0;
            default:  result = 32'd0; // default case
        endcase
    end
endmodule