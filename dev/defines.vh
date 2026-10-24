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

// Djef fixing instruction defs, more descriptive even though some are redundant
// might be used later
//****************************************************************************//

//ARITHMETIC INSTRS

//RTYPE
//ADD
`define ADD_OPCODE          7'b011_0011
`define ADD_FUNCT3          3'b000
`define ADD_FUNCT7          7'b000_0000
//SUB
`define SUB_OPCODE          7'b011_0011
`define SUB_FUNCT3          3'b000
`define SUB_FUNCT7          7'b010_0000
//AND
`define AND_OPCODE          7'b011_0011
`define AND_FUNCT3          3'b111
`define AND_FUNCT7          7'b000_0000
//OR
`define OR_OPCODE           7'b011_0011
`define OR_FUNCT3           3'b110
`define OR_FUNCT7           7'b000_0000
//XOR
`define XOR_OPCODE          7'b011_0011
`define XOR_FUNCT3          3'b100
`define XOR_FUNCT7          7'b000_0000
//SLL
`define SLL_OPCODE          7'b011_0011
`define SLL_FUNCT3          3'b001
`define SLL_FUNCT7          7'b000_0000
//SRL
`define SRL_OPCODE          7'b011_0011
`define SRL_FUNCT3          3'b101
`define SRL_FUNCT7          7'b000_0000
//SRA
`define SRA_OPCODE          7'b011_0011
`define SRA_FUNCT3          3'b101
`define SRA_FUNCT7          7'b010_0000
//SLT
`define SLT_OPCODE          7'b011_0011
`define SLT_FUNCT3          3'b010
`define SLT_FUNCT7          7'b000_0000
//SLTU
`define SLTU_OPCODE         7'b011_0011
`define SLTU_FUNCT3         3'b011
`define SLTU_FUNCT7         7'b000_0000

//ITYPE
//ADDI
`define ADDI_OPCODE         7'b001_0011
`define ADDI_FUNCT3         3'b000
//ANDI
`define ANDI_OPCODE         7'b001_0011
`define ANDI_FUNCT3         3'b111
//ORI
`define ORI_OPCODE          7'b001_0011
`define ORI_FUNCT3          3'b110
//XORI
`define XORI_OPCODE         7'b001_0011
`define XORI_FUNCT3         3'b100
//SLTI
`define SLTI_OPCODE         7'b001_0011
`define SLTI_FUNCT3         3'b010
//SLTIU
`define SLTIU_OPCODE        7'b001_0011
`define SLTIU_FUNCT3        3'b011
//SLLI
`define SLLI_OPCODE         7'b001_0011
`define SLLI_FUNCT3         3'b001
`define SLLI_FUNCT7         7'b000_0000
//SRLI
`define SRLI_OPCODE         7'b001_0011
`define SRLI_FUNCT3         3'b101
`define SRLI_FUNCT7         7'b000_0000
//SRAI
`define SRAI_OPCODE         7'b001_0011
`define SRAI_FUNCT3         3'b101
`define SRAI_FUNCT7         7'b010_0000


//MEMORY INSTRS

//ITYPE
//LB
`define LB_OPCODE           7'b000_0011
`define LB_FUNCT3           3'b000
//LBU
`define LBU_OPCODE          7'b000_0011
`define LBU_FUNCT3          3'b100
//LH
`define LH_OPCODE           7'b000_0011
`define LH_FUNCT3           3'b001
//LHU
`define LHU_OPCODE          7'b000_0011
`define LHU_FUNCT3          3'b101
//LW
`define LW_OPCODE           7'b000_0011
`define LW_FUNCT3           3'b010
//STYPE
//SB
`define SB_OPCODE           7'b010_0011
`define SB_FUNCT3           3'b000
//SH
`define SH_OPCODE           7'b010_0011
`define SH_FUNCT3           3'b001
//SW
`define SW_OPCODE           7'b010_0011
`define SW_FUNCT3           3'b010


//CONTROL INSTRS

//BTYPE
//BEQ
`define BEQ_OPCODE          7'b110_0011
`define BEQ_FUNCT3          3'b000
//BNE
`define BNE_OPCODE          7'b110_0011
`define BNE_FUNCT3          3'b001
//BLT
`define BLT_OPCODE          7'b110_0011
`define BLT_FUNCT3          3'b100
//BLTU
`define BLTU_OPCODE         7'b110_0011
`define BLTU_FUNCT3         3'b110
//BGE
`define BGE_OPCODE          7'b110_0011
`define BGE_FUNCT3          3'b101
//BGEU
`define BGEU_OPCODE         7'b110_0011
`define BGEU_FUNCT3         3'b111

//JTYPE
//JAL
`define JAL_OPCODE          7'b110_1111

//ITYPE
//JALR
`define JALR_OPCODE         7'b110_0111
`define JALR_FUNCT3         3'b000
//****************************************************************************//

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



//caching
`define NUM_DCACHE_LANES 3'd4




`endif