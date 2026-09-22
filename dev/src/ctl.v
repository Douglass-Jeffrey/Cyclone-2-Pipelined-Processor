`include "defines.vh"

//resolve alu inputs, branching etc
module ctl (
    input wire [31:0]   instr,
    output wire [4:0]   rs1_addr,
    output wire [4:0]   rs2_addr,
    output wire [4:0]   rd_addr,
    output reg          reg_write,

    // need these two to indicate forwarding
    output reg          uses_rs1,
    output reg          uses_rs2,

    output reg [2:0]    imm_type,      //to imm_gen

    output reg [3:0]    alu_op,        //to alu_ctl
    output reg          alu_a_src,
    output reg          alu_b_src,    
    
    output reg          mem_read,      //to data_mem
    output reg          mem_write,     //to data_mem

    output reg [1:0]    wb_src,        //to wb_mux
    
    output reg          branch,        //to pc_mux
    output reg          jal,
    output reg          jalr
);

    //standard rv32i parsing into fields
    wire [6:0]  opcode   = instr[6:0];
    wire [2:0]  funct3   = instr[14:12];
    wire        funct7b5 = instr[30];
    wire        is_rtype = (opcode == `RTYPE_OPCODE);

    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];

    always @(*) begin
        //default values
        alu_a_src  = `ALU_A_RS1;
        alu_b_src  = `ALU_B_RS2;
        wb_src     = `WB_ALU;
        alu_op     = `ALUOP_ADD;
        imm_type   = `IMM_I;

        mem_read   = 1'b0;
        mem_write  = 1'b0;
        reg_write  = 1'b0;
        uses_rs1   = 1'b0;
        uses_rs2   = 1'b0;

        branch     = 1'b0;
        jal        = 1'b0;
        jalr       = 1'b0;

        case (opcode)
            `BRANCH_OPCODE: begin
                imm_type    = `IMM_B;
                branch      = 1'b1;
                uses_rs1    = 1'b1;
                uses_rs2    = 1'b1;
                case (funct3)
                    3'b000: alu_op = `ALU_SUB;   // beq check zero
                    3'b001: alu_op = `ALU_SUB;   // bne check !zero
                    3'b100: alu_op = `ALU_SLT;   // blt check result==1
                    3'b101: alu_op = `ALU_SLT;   // bge check result==0
                    3'b110: alu_op = `ALU_SLTU;  // bltu
                    3'b111: alu_op = `ALU_SLTU;  // bgeu
                    default: alu_op = `ALU_SUB;
                endcase
            end
            `LOAD_OPCODE: begin
                mem_read    = 1'b1;
                wb_src      = `WB_MEM;
                alu_op      = `ALUOP_ADD; //load
                alu_b_src   = `ALU_B_IMM;
                reg_write   = 1'b1;
                imm_type    = `IMM_I;
                uses_rs1    = 1'b1;
            end
            `STORE_OPCODE: begin
                alu_op      = `ALUOP_ADD; //store
                mem_write   = 1'b1;
                alu_b_src   = `ALU_B_IMM;
                imm_type    = `IMM_S;
                uses_rs1    = 1'b1;
                uses_rs2    = 1'b1;   // store data
            end
            `RTYPE_OPCODE: begin
                reg_write   = 1'b1;
                uses_rs1    = 1'b1;
                uses_rs2    = 1'b1;
                case (funct3)
                    3'b000: alu_op = (is_rtype && funct7b5) ? `ALU_SUB : `ALU_ADD;
                    3'b001: alu_op = `ALU_SLL;
                    3'b010: alu_op = `ALU_SLT;
                    3'b011: alu_op = `ALU_SLTU;
                    3'b100: alu_op = `ALU_XOR;
                    3'b101: alu_op = funct7b5 ? `ALU_SRA : `ALU_SRL;
                    3'b110: alu_op = `ALU_OR;
                    3'b111: alu_op = `ALU_AND;
                    default: alu_op = `ALU_ADD;
                endcase
            end
            // imm and rtype have same funct3 values for cmds
            `IMM_OPCODE: begin
                alu_b_src   = `ALU_B_IMM;
                reg_write   = 1'b1;
                imm_type    = `IMM_I;
                uses_rs1    = 1'b1;
                case (funct3)
                    3'b000: alu_op = (is_rtype && funct7b5) ? `ALU_SUB : `ALU_ADD;
                    3'b001: alu_op = `ALU_SLL;
                    3'b010: alu_op = `ALU_SLT;
                    3'b011: alu_op = `ALU_SLTU;
                    3'b100: alu_op = `ALU_XOR;
                    3'b101: alu_op = funct7b5 ? `ALU_SRA : `ALU_SRL;
                    3'b110: alu_op = `ALU_OR;
                    3'b111: alu_op = `ALU_AND;
                    default: alu_op = `ALU_ADD;
                endcase
            end
            `JAL_OPCODE: begin
                jal         = 1'b1;
                alu_op      = `ALUOP_ADD; //jal
                alu_b_src   = `ALU_B_IMM;
                reg_write   = 1'b1;
                imm_type    = `IMM_J;
                wb_src      = `WB_PC4; //rd = pc+4, target comes from pc_target
            end
            `JALR_OPCODE: begin
                jal         = 1'b1;
                jalr        = 1'b1; //target = (rs1+immI) & ~1, not pc+imm
                alu_op      = `ALUOP_ADD; //jalr
                alu_b_src   = `ALU_B_IMM;
                reg_write   = 1'b1;
                imm_type    = `IMM_I;
                uses_rs1    = 1'b1;
                wb_src      = `WB_PC4; //rd = pc+4
            end
            `LUI_OPCODE: begin
                alu_b_src   = `ALU_B_IMM;
                reg_write   = 1'b1;
                imm_type    = `IMM_U;
                wb_src      = `WB_IMM; //rd = imm (no rs1 term)
            end
            `AUIPC_OPCODE: begin
                alu_b_src   = `ALU_B_IMM;
                alu_a_src   = `ALU_A_PC; //rd = pc + imm
                alu_op      = `ALUOP_ADD; //auipc
                reg_write   = 1'b1;
                imm_type    = `IMM_U;
            end
            `FENCE_OPCODE: begin
                wb_src      = `WB_ALU; //fence
                alu_op      = `ALUOP_ADD; //fence
            end
            `SYSTEM_OPCODE: begin
                // funct3 == 000 : ECALL / EBREAK / xRET -> no trap support, treat as NOP.
                // funct3 != 000 : CSRRW/S/C[I] -> old CSR value is written back to rd.
                // out of scope for now but maybe in future
                if (funct3 != 3'b000) begin
                    reg_write = 1'b1;
                end
            end
            default: begin
                branch      = 1'b0;
                mem_read    = 1'b0;
                wb_src      = `WB_ALU; //default to ALU
                alu_op      = `ALUOP_ADD; //default to add
                mem_write   = 1'b0;
                alu_b_src   = 1'b0;
                reg_write   = 1'b0;
            end
        endcase
    end
endmodule


/*
module alu_ctl (
    input wire [1:0] alu_op_from_ctl,   //from main ctl
    input wire [2:0] funct3,            //from instr
    input wire funct7b5,                //from instr, bit 30 
    input wire is_rtype,                //from main ctl
    output reg [3:0] alu_op             //to alu
);
always @(*) begin
    case (alu_op_from_ctl)
        `ALUOP_ADD: begin
            alu_op = `ALU_ADD; //add
        end
        `ALUOP_BRANCH: begin
            case (funct3)
                3'b000: alu_op = `ALU_SUB;   // beq check zero
                3'b001: alu_op = `ALU_SUB;   // bne check !zero
                3'b100: alu_op = `ALU_SLT;   // blt check result==1
                3'b101: alu_op = `ALU_SLT;   // bge check result==0 (i.e. !(a<b))
                3'b110: alu_op = `ALU_SLTU;  // bltu
                3'b111: alu_op = `ALU_SLTU;  // bgeu
                default: alu_op = `ALU_SUB;
            endcase
        end
        `ALUOP_RTYPE: begin
            case (funct3)
                3'b000: alu_op = (is_rtype && funct7b5) ? `ALU_SUB : `ALU_ADD;
                3'b001: alu_op = `ALU_SLL;
                3'b010: alu_op = `ALU_SLT;
                3'b011: alu_op = `ALU_SLTU;
                3'b100: alu_op = `ALU_XOR;
                3'b101: alu_op = funct7b5 ? `ALU_SRA : `ALU_SRL;
                3'b110: alu_op = `ALU_OR;
                3'b111: alu_op = `ALU_AND;
                default: alu_op = `ALU_ADD;
            endcase
        end
        default: begin
            alu_op = `ALU_ADD;
        end
    endcase
end
endmodule
*/

