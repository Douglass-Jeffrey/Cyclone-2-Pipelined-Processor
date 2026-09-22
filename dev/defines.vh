`ifndef DEFINES_VH
`define DEFINES_VH

//ALU_CTL codes
`define ALUOP_ADD           2'b00 //Add
`define ALUOP_BRANCH        2'b01 //Branch
`define ALUOP_RTYPE         2'b10 //R-type

//ALU codes
`define ALU_ADD             4'd0 //add
`define ALU_SUB             4'd1 //sub
`define ALU_AND             4'd2 //and
`define ALU_OR              4'd3 //or
`define ALU_XOR             4'd4 //xor
`define ALU_SLL             4'd5 //shift left logical
`define ALU_SRL             4'd6 //shift right logical
`define ALU_SRA             4'd7 //shift right arithmetic
`define ALU_SLT             4'd8 //set less than
`define ALU_SLTU            4'd9 //set less than unsigned

//CTL opcodes
//standard
`define NOP_OPCODE          7'b0000000
`define RTYPE_OPCODE        7'b0110011
`define IMM_OPCODE          7'b0010011
`define BRANCH_OPCODE       7'b1100011
`define STORE_OPCODE        7'b0100011
`define LOAD_OPCODE         7'b0000011

//unconditional jumps
`define JAL_OPCODE          7'b1101111
`define JALR_OPCODE         7'b1100111
`define LUI_OPCODE          7'b0110111
`define AUIPC_OPCODE        7'b0010111

//misc
`define FENCE_OPCODE        7'b0001111
`define SYSTEM_OPCODE       7'b1110011  //ECALL/EBREAK/xRET + Zicsr, disambiguated by funct3

//IMM_GEN immediate type select (from decode, based on opcode)
`define IMM_I               3'd0
`define IMM_S               3'd1
`define IMM_B               3'd2
`define IMM_U               3'd3
`define IMM_J               3'd4

// defines for ctl.v_alu_a_src: ALU A select, if ALU_A_RS1==0, rs1 selected else pc selected
`define ALU_A_RS1  1'b0
`define ALU_A_PC   1'b1
`define ALU_B_RS2  1'b0
`define ALU_B_IMM  1'b1

// defines for ctl.v_wb_src: 0 is ALU, 1 is MEM, 2 is PC+4, 3 is IMM
`define WB_ALU     2'd0
`define WB_MEM     2'd1
`define WB_PC4     2'd2
`define WB_IMM     2'd3

// forwarding_unit select codes
`define FWD_NONE   2'd0   // use the value read from the regfile in ID
`define FWD_MEM    2'd1   // result of the instruction now in MEM
`define FWD_WB     2'd2   // result of the instruction now in WB

`endif