`include "defines.vh"

//multi-cycle pipelined RV32I datapath
// no BP yet, all are implicitely not taken 
module pipelined_datapath #(
    parameter RESET_PC  = 32'h0000_0000,
    parameter IMEM_INIT = "program.hex"
) (
    input  wire        clk,
    input  wire        rst,
    // output for instructions retiring this cycle fed to TB, quartus board wrapper
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_instr,
    output wire [31:0] dbg_wb_data,
    output wire        dbg_reg_write, 
    // more quartus board wrapper outputs
    output wire [31:0] dbg_if_pc,           // pc of the instruction in ID
    output wire        dbg_retire_valid,    // a real instruction retired this cycle
    output wire        dbg_stall,           // load-use interlock held the front end
    output wire        dbg_redirect         // branch/jump flushed the front end
);
    //PIPELINE IF STAGE================================================================================
    // branch prediction will take place in this stage, actual branch will resolve in the EX stage
    //for branches, jal, jalr, auipc
    wire redirect;
    wire [31:0] redirect_pc;

    // hold pc and if/id stable when a dmem accessing RAW dependency occurs
    wire stall;    

    //ifid regs
    wire [31:0] if_id_instr;    // written by instr mem
    reg  [31:0] if_id_pc;       // pc of instr in id
    reg         if_id_valid;

    //DJEF BP STUFF HERE LATER (including defined BP module)
    //for branch prediction to occur in IF stage we need to be able to read the instr in the if stage
    //we just need to parse

    // next_pc sent to id stage will be redirected if theres a branch or jump
    // else if theres a stall send the same PC again, else increment by 4 to get next instr
    wire [31:0] next_pc = redirect ? redirect_pc
            : stall ? if_id_pc
            : if_id_pc + 32'd4;

    // fetch instruction from memory
    // the M4K mem blocks can latch addr then present data on next CC
    // We need to consider this when deciding how instruction data gets to next stage
    // DJEF TODO imem, dmem caching and arbiter
    imem #(
        .DEPTH_WORDS (512),
        .INIT_FILE   (IMEM_INIT)
    ) u_imem (
        .clk   (clk),
        .addr  (next_pc),
        .instr (if_id_instr)
    );

    //pipeline logic
    always @(posedge clk) begin
        if (rst) begin
            if_id_pc    <= RESET_PC - 32'd4;
            if_id_valid <= 1'b0;
        end
        else begin
            if_id_pc    <= next_pc;
            if_id_valid <= 1'b1;
        end
    end

    // PIPELINE ID STAGE================================================================================
    // Main control
    wire [4:0] rs1_addr, rs2_addr, id_rd_addr;
    wire [3:0] alu_op;
    wire [2:0] imm_type;
    wire [1:0] wb_src;
    wire       id_reg_write, alu_a_src, alu_b_src, mem_read, mem_write, branch, jal, jalr;
    wire       uses_rs1, uses_rs2;

    // Do all of the relevant decode and control logic
    ctl u_ctl (
        .instr     (if_id_instr),
        .rs1_addr  (rs1_addr),
        .rs2_addr  (rs2_addr),
        .rd_addr   (id_rd_addr),
        .reg_write (id_reg_write),
        .uses_rs1  (uses_rs1),
        .uses_rs2  (uses_rs2),
        .imm_type  (imm_type), //to immgen
        .alu_op    (alu_op),
        .alu_a_src (alu_a_src),
        .alu_b_src (alu_b_src),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .wb_src    (wb_src),
        .branch    (branch),
        .jal       (jal),
        .jalr      (jalr)
    );

    // Immediate generator
    wire [31:0] imm;
    imm_gen u_imm (
        .instr    (if_id_instr),
        .imm_type (imm_type),
        .imm      (imm)
    );

    // Registers fetched for id
    wire [31:0] rs1_data, rs2_data;

    // register information written in WB stage
    reg  [31:0] wb_data;
    reg  [4:0]  rd_addr;
    reg         reg_write;

    regfile u_rf (
        .clk      (clk),
        .rst      (rst),
        .rs1_addr (rs1_addr),
        .rs2_addr (rs2_addr),
        .rd_addr  (rd_addr),
        .rd_data  (wb_data),
        .rd_we    (reg_write),
        .rs1_data (rs1_data),
        .rs2_data (rs2_data)
    );

    // id_ex_regs
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_instr;
    reg [31:0] id_ex_imm;
    reg [31:0] id_ex_rs1_data;
    reg [31:0] id_ex_rs2_data;
    reg [4:0]  id_ex_rs1_addr;
    reg [4:0]  id_ex_rs2_addr;
    reg [4:0]  id_ex_rd_addr;
    reg [3:0]  id_ex_alu_op;
    //reg [2:0]  id_ex_imm_type;
    reg [2:0]  id_ex_funct3;
    reg [1:0]  id_ex_wb_src;
    reg        id_ex_reg_write;
    reg        id_ex_alu_a_src;
    reg        id_ex_alu_b_src;
    reg        id_ex_mem_read;
    reg        id_ex_mem_write;
    reg        id_ex_branch;
    reg        id_ex_jal;
    reg        id_ex_jalr;
    reg        id_ex_valid;

    wire ex_bubble;
    hazard_unit u_hazard (
        .id_valid       (if_id_valid),
        .id_rs1_addr    (rs1_addr),
        .id_rs2_addr    (rs2_addr),
        .id_uses_rs1    (uses_rs1),
        .id_uses_rs2    (uses_rs2),
        .id_mem_write   (mem_write),
        .ex_valid       (id_ex_valid),
        .ex_mem_read    (id_ex_mem_read),
        .ex_rd_addr     (id_ex_rd_addr),
        .redirect       (redirect),
        .if_stall       (stall),
        .ex_bubble      (ex_bubble)
    );

    // id_ex allocations:
    always @(posedge clk) begin
        if (rst) begin
            id_ex_valid <= 1'b0;
        end
        // occurs on load->use stall, or redirect
        else if (ex_bubble) begin
            id_ex_valid <= 1'b0;
        end
        else begin
            id_ex_valid     <= if_id_valid;
            id_ex_pc        <= if_id_pc;
            id_ex_instr     <= if_id_instr;
            id_ex_imm       <= imm;

            id_ex_rs1_data  <= rs1_data;
            id_ex_rs2_data  <= rs2_data;
            id_ex_rs1_addr  <= rs1_addr;
            id_ex_rs2_addr  <= rs2_addr;
            id_ex_rd_addr   <= id_rd_addr;

            id_ex_alu_op    <= alu_op;
            id_ex_alu_a_src <= alu_a_src;
            id_ex_alu_b_src <= alu_b_src;

            id_ex_wb_src    <= wb_src;
            id_ex_reg_write <= id_reg_write;

            id_ex_mem_read  <= mem_read;
            id_ex_mem_write <= mem_write;

            id_ex_branch    <= branch;
            id_ex_jal       <= jal;
            id_ex_jalr      <= jalr;
        end
    end

    // PIPELINE EX STAGE================================================================================

    // ex_mem_regs
    reg [31:0] ex_mem_pc;
    reg [31:0] ex_mem_instr;
    //reg [31:0] ex_mem_imm;
    reg [31:0] ex_mem_alu_result;
    // reg [31:0] ex_mem_rs1_data;
    reg [31:0] ex_mem_rs2_data;
    reg [31:0] ex_mem_wb_data;
    // reg [4:0]  ex_mem_rs1_addr;
    reg [4:0]  ex_mem_rs2_addr;
    reg [4:0]  ex_mem_rd_addr;
    // reg [3:0]  ex_mem_alu_op;
    //reg [2:0]  ex_mem_imm_type;
    reg [2:0]  ex_mem_funct3;
    reg [1:0]  ex_mem_wb_src;
    reg        ex_mem_reg_write;
    //reg        ex_mem_alu_a_src;
    //reg        ex_mem_alu_b_src;
    reg        ex_mem_mem_read;
    reg        ex_mem_mem_write;
    //reg        ex_mem_branch;
    //reg        ex_mem_jal;
    //reg        ex_mem_jalr;
    reg        ex_mem_valid;

    // mem_wb_regs
    reg [31:0] mem_wb_pc;
    reg [31:0] mem_wb_instr;
    //reg [31:0] mem_wb_imm;
    //reg [31:0] mem_wb_alu_result;
    //reg [31:0] mem_wb_rs1_data;
    //reg [31:0] mem_wb_rs2_data;
    reg [31:0] mem_wb_wb_data;
    //reg [4:0]  mem_wb_rs1_addr;
    //reg [4:0]  mem_wb_rs2_addr;
    reg [4:0]  mem_wb_rd_addr;
    //reg [3:0]  mem_wb_alu_op;
    //reg [2:0]  mem_wb_imm_type;
    reg [2:0]  mem_wb_funct3;
    reg [1:0]  mem_wb_wb_src;
    reg        mem_wb_reg_write;
    //reg        mem_wb_alu_a_src;
    //reg        mem_wb_alu_b_src;
    reg        mem_wb_mem_read;
    //reg        mem_wb_mem_write;
    //reg        mem_wb_branch;
    //reg        mem_wb_jal;
    //reg        mem_wb_jalr;
    reg        mem_wb_valid;

    // forwarding logic
    wire [1:0] fwd_a, fwd_b;
    forwarding_unit u_fwd (
        .ex_rs1_addr   (id_ex_rs1_addr),
        .ex_rs2_addr   (id_ex_rs2_addr),
        .mem_valid     (ex_mem_valid),
        .mem_reg_write (ex_mem_reg_write),
        .mem_rd_addr   (ex_mem_rd_addr),
        .wb_valid      (mem_wb_valid),
        .wb_reg_write  (mem_wb_reg_write),
        .wb_rd_addr    (mem_wb_rd_addr),
        .fwd_a         (fwd_a),
        .fwd_b         (fwd_b)
    );

    wire [31:0] ex_rs1_val = (fwd_a == `FWD_MEM) ? ex_mem_wb_data :
                             (fwd_a == `FWD_WB)  ? wb_data        : id_ex_rs1_data;
    wire [31:0] ex_rs2_val = (fwd_b == `FWD_MEM) ? ex_mem_wb_data :
                             (fwd_b == `FWD_WB)  ? wb_data        : id_ex_rs2_data;

    wire [31:0] alu_a = (id_ex_alu_a_src == `ALU_A_PC)  ? id_ex_pc  : ex_rs1_val;
    wire [31:0] alu_b = (id_ex_alu_b_src == `ALU_B_IMM) ? id_ex_imm : ex_rs2_val;

    wire [31:0] alu_result;
    wire        zero_flag;

    alu u_alu (
        .a         (alu_a),
        .b         (alu_b),
        .alu_op    (id_ex_alu_op),
        .result    (alu_result)
        //.zero_flag (zero_flag)
    );

    // Decide WB contents 
    reg [31:0] ex_wb_data;
    always @(*) begin
        case (id_ex_wb_src)
            `WB_PC4: ex_wb_data = id_ex_pc + 32'd4;
            `WB_IMM: ex_wb_data = id_ex_imm;
            default: ex_wb_data = alu_result;   // WB_ALU (WB_MEM is replaced by load data in WB)
        endcase
    end

    // move branch compute logic outside of alu for speedup
    // we dont have to wait for srl, muxing now
    // dedicated comparator
    wire [2:0]  funct3     = id_ex_instr[14:12];
    wire        bc_beq     = (funct3 == 3'b000)  && (ex_rs1_val == ex_rs2_val);
    wire        bc_bne     = (funct3 == 3'b001)  && (ex_rs1_val != ex_rs2_val);
    wire        bc_blt     = (funct3 == 3'b100)  && ($signed(ex_rs1_val) < $signed(ex_rs2_val));
    wire        bc_bge     = (funct3 == 3'b101)  && ($signed(ex_rs1_val) >= $signed(ex_rs2_val));
    wire        bc_bltu    = (funct3 == 3'b110)  && (ex_rs1_val < ex_rs2_val);
    wire        bc_bgeu    = (funct3 == 3'b111)  && (ex_rs1_val >= ex_rs2_val);

/*
    reg cond;
    always @(*) begin
        case (id_ex_instr[14:12]) //funct3
            3'b000: cond =  zero_flag;   // BEQ
            3'b001: cond = ~zero_flag;   // BNE
            3'b100: cond = ~zero_flag;   // BLT
            3'b101: cond =  zero_flag;   // BGE
            3'b110: cond = ~zero_flag;   // BLTU
            3'b111: cond =  zero_flag;   // BGEU
            default: cond = 1'b0;
        endcase
    end
*/
    // branch / jump indicators
    wire any_branch =   bc_beq
                    ||  bc_bne 
                    ||  bc_blt
                    ||  bc_bltu
                    ||  bc_bge
                    ||  bc_bgeu;
    wire take_branch = id_ex_branch && any_branch;
    wire jump = id_ex_jal || id_ex_jalr;

    // next-PC mux
    wire [31:0] pc_target   = id_ex_pc + id_ex_imm;      // branch immB / JAL immJ
    wire [31:0] jalr_target = {alu_result[31:1], 1'b0};  // rs1 + immI, bit 0 cleared (jalr)

    assign redirect = (jump || take_branch) && id_ex_valid; // need id_ex valid so bubble doesnt count as redirect
    assign redirect_pc = id_ex_jalr ? jalr_target : pc_target;

    //ex_mem allocations:
    always @(posedge clk) begin
        if (rst) begin
            ex_mem_valid <= 1'b0;
        end
        else begin
            ex_mem_valid        <= id_ex_valid;
            ex_mem_pc           <= id_ex_pc;
            ex_mem_instr        <= id_ex_instr;
            //ex_mem_imm          <= id_ex_imm;
            ex_mem_alu_result   <= alu_result;
            ex_mem_wb_data      <= ex_wb_data;

            //ex_mem_rs1_data     <= id_ex_rs1_data; //prob dont need
            ex_mem_rs2_data     <= ex_rs2_val;     // store data: must be the forwarded value
            //ex_mem_rs1_addr     <= id_ex_rs1_addr; //prob dont need
            ex_mem_rs2_addr     <= id_ex_rs2_addr; 
            ex_mem_rd_addr      <= id_ex_rd_addr;

            //ex_mem_alu_op       <= id_ex_alu_op;   //prob dont need
            //ex_mem_alu_a_src    <= id_ex_alu_a_src;//prob dont need
            //ex_mem_alu_b_src    <= id_ex_alu_b_src;//prob dont need

            ex_mem_wb_src       <= id_ex_wb_src;
            ex_mem_reg_write    <= id_ex_reg_write;

            ex_mem_mem_read     <= id_ex_mem_read;
            ex_mem_mem_write    <= id_ex_mem_write;

            //ex_mem_branch       <= id_ex_branch;  //prob dont need
            //ex_mem_jal          <= id_ex_jal;     //prob dont need
            //ex_mem_jalr         <= id_ex_jalr;    //prob dont need
        end
    end

    // PIPELINE MEM STAGE================================================================================
    // Data memory
    // The address is latched at the end of this cycle and load_data is presented
    // during the NEXT cycle (the load's WB stage), so load_data is consumed in
    // WB directly instead of being copied into mem_wb.
    wire [31:0] load_data, mem_store_data;
    wire        load_store_mem_fwd;

    // djeffrey load->store forwarding, if prev cycle was valid read and rdaddr == rs2addr, store the data we just loaded
    assign load_store_mem_fwd = mem_wb_mem_read
                                && mem_wb_valid
                                && mem_wb_rd_addr != 5'd0
                                && (mem_wb_rd_addr == ex_mem_rs2_addr);
    assign mem_store_data = load_store_mem_fwd ? load_data : ex_mem_rs2_data;

    dmem #(
        .DEPTH_WORDS (256)
    ) u_dmem (
        .clk       (clk),
        .valid     (ex_mem_valid),
        .addr      (ex_mem_alu_result), // read addr for load, store computed from alu
        .funct3    (ex_mem_instr[14:12]),
        .mem_read  (ex_mem_mem_read),
        .mem_write (ex_mem_mem_write),
        .wdata     (mem_store_data),
        .rdata     (load_data)
    );

    //mem_wb allocations:
    always @(posedge clk) begin
        if (rst) begin
            mem_wb_valid        <= 1'b0;
        end
        else begin
            mem_wb_valid        <= ex_mem_valid;
            mem_wb_pc           <= ex_mem_pc;
            mem_wb_instr        <= ex_mem_instr;
            //mem_wb_imm          <= ex_mem_imm;
            //mem_wb_alu_result   <= ex_mem_alu_result;
            mem_wb_wb_data      <= ex_mem_wb_data;

            //mem_wb_rs1_data     <= ex_mem_rs1_data; //prob dont need
            //mem_wb_rs2_data     <= ex_mem_rs2_data; //prob_dont need
            //mem_wb_rs1_addr     <= ex_mem_rs1_addr; //prob dont need
            //mem_wb_rs2_addr     <= ex_mem_rs2_addr; //prob dont need
            mem_wb_rd_addr      <= ex_mem_rd_addr;

            //mem_wb_alu_op       <= ex_mem_alu_op;   //prob dont need
            //mem_wb_alu_a_src    <= ex_mem_alu_a_src;//prob dont need
            //mem_wb_alu_b_src    <= ex_mem_alu_b_src;//prob dont need

            mem_wb_wb_src       <= ex_mem_wb_src;
            mem_wb_reg_write    <= ex_mem_reg_write;

            mem_wb_mem_read     <= ex_mem_mem_read; //prob dont need
            //mem_wb_mem_write    <= ex_mem_mem_write;//prob dont need

            //mem_wb_branch       <= ex_mem_branch;  //prob dont need
            //mem_wb_jal          <= ex_mem_jal;     //prob dont need
            //mem_wb_jalr         <= ex_mem_jalr;    //prob dont need
        end
    end


    // PIPELINE WB STAGE================================================================================

    // wb mux
    always @(*) begin
        reg_write   = mem_wb_valid && mem_wb_reg_write;
        rd_addr     = mem_wb_rd_addr;
        // everything except a load was already resolved in EX
        wb_data     = (mem_wb_wb_src == `WB_MEM) ? load_data : mem_wb_wb_data;
    end

    // Debug taps
    assign dbg_pc        = mem_wb_pc;
    assign dbg_instr     = mem_wb_instr;
    assign dbg_wb_data   = wb_data;
    assign dbg_reg_write = reg_write;

    assign dbg_if_pc        = if_id_pc;
    assign dbg_retire_valid = mem_wb_valid;
    assign dbg_stall        = stall;
    assign dbg_redirect     = redirect;

endmodule
