`include "defines.vh"

//multi-cycle pipelined RV32I datapath
// 2-bit branch predictor in ID, branches checked in EX
// 8 KB I-cache + 16 KB D-cache (all 52 M4Ks) in front of the board's SRAM:
//   code region SRAM 0x00000-0x3FFFF (pc[17:0]), data region 0x40000-0x7FFFF (addr[17:0])
module pipelined_datapath #(
    parameter RESET_PC   = 32'h0000_0000,
    parameter IMEM_INIT  = "program.hex",   // I-cache power-up contents (first 8 KB of code)
    parameter CLEAR_SRAM = 0                // 1: zero the data region at reset (board)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        clk_en,
    // output for instructions retiring this cycle fed to TB, quartus board wrapper
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_instr,
    output wire [31:0] dbg_wb_data,
    output wire        dbg_reg_write,
    // more quartus board wrapper outputs
    output wire [31:0] dbg_if_pc,           // pc of the instruction in ID
    output wire        dbg_retire_valid,    // a real instruction retired this cycle
    output wire        dbg_stall,           // load-use interlock held the front end
    output wire        dbg_redirect,        // branch/jump flushed the front end
    // memory system
    output wire        dbg_mem_ready,       // reset sweep done; the program starts now
    output wire        dbg_dmiss,           // one-cycle pulses on the raw clock
    output wire        dbg_dwriteback,
    output wire        dbg_imiss,
    // board SRAM
    output wire [17:0] SRAM_ADDR,
    inout  wire [15:0] SRAM_DQ,
    output wire        SRAM_CE_N,
    output wire        SRAM_OE_N,
    output wire        SRAM_WE_N,
    output wire        SRAM_UB_N,
    output wire        SRAM_LB_N
);
    // a D-cache miss freezes every stage exactly like clk_en low; the caches'
    // controllers, the arbiter and sram_ctl keep running on the raw clock
    wire dc_busy;
    wire pipe_en = clk_en && !dc_busy;

    //PIPELINE IF STAGE================================================================================
    // branch prediction will take place in this stage, actual branch will resolve in the EX stage
    //for branches, jal, jalr
    wire redirect;
    wire b_p;
    wire [31:0] branch_pred_pc;
    wire bp_upd_valid, bp_upd_taken;

    // hold pc and if/id stable when a dmem accessing RAW dependency occurs,
    // or while the I-cache fetches the line for the instruction in ID
    wire stall;

    //ifid regs
    wire [31:0] if_id_instr;    // written by instr mem
    reg  [31:0] if_id_pc;       // pc of instr in id
    reg         if_id_valid;

    // next_pc sent to id stage will be redirected if theres a branch or jump
    // else if theres a stall send the same PC again, else increment by 4 to get next instr
    // (the redirect half of the mux is built in EX, where the compare is)
    wire [31:0] fetch_pc = stall ? if_id_pc
                         : b_p ? branch_pred_pc
                         : if_id_pc + 32'd4;
    wire [31:0] next_pc;

    // fetch instruction from the I-cache: addressed by next_pc, word ready in ID
    // a miss holds the fetch (stall) and bubbles EX until the line is in
    wire        ihit;
    wire        imiss = if_id_valid && !ihit;
    wire        ic_req, ic_ack;
    wire [17:0] ic_addr;
    wire [127:0] mem_rdata;

    icache #(
        .INIT_FILE (IMEM_INIT)
    ) u_icache (
        .clk       (clk),
        .rst       (rst),
        .pipe_en   (pipe_en),
        .next_pc   (next_pc),
        .pc        (if_id_pc),
        .fetch_req (if_id_valid && !redirect),  // a flushed fetch needs no refill
        .instr     (if_id_instr),
        .hit       (ihit),
        .mreq      (ic_req),
        .maddr     (ic_addr),
        .mrdata    (mem_rdata),
        .mack      (ic_ack),
        .ev_miss   (dbg_imiss)
    );

    //pipeline logic
    // pipe_en low holds every stage, valid bits included (clearing them drops the instr)
    always @(posedge clk) begin
        if (rst) begin
            if_id_pc    <= RESET_PC - 32'd4;
            if_id_valid <= 1'b0;
        end
        else if (pipe_en) begin
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
        .clk_en   (pipe_en),
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
    reg        id_ex_b_p;
    reg        id_ex_valid;

    // predicts the instr in ID, trained by the branch resolving in EX
    branch_predictor u_bp (
    .clk                (clk),
    .rst                (rst),
    .clk_en             (pipe_en),
    .valid              (if_id_valid),
    .pc                 (if_id_pc),
    .jal                (jal),
    .jalr               (jalr),
    .branch             (branch),
    .imm                (imm),
    .pred_take_branch   (b_p),
    .bp_pc              (branch_pred_pc),
    .upd_valid          (bp_upd_valid),
    .upd_pc             (id_ex_pc),
    .upd_taken          (bp_upd_taken)
    );

    // an I-cache miss leaves junk in ID: it must not interlock, and it bubbles EX
    wire lu_stall, hz_bubble;
    wire ex_bubble = hz_bubble || imiss;
    assign stall   = lu_stall  || imiss;
    hazard_unit u_hazard (
        .id_valid       (if_id_valid && ihit),
        .id_rs1_addr    (rs1_addr),
        .id_rs2_addr    (rs2_addr),
        .id_uses_rs1    (uses_rs1),
        .id_uses_rs2    (uses_rs2),
        .id_mem_write   (mem_write),
        .ex_valid       (id_ex_valid),
        .ex_mem_read    (id_ex_mem_read),
        .ex_rd_addr     (id_ex_rd_addr),
        .redirect       (redirect),
        .if_stall       (lu_stall),
        .ex_bubble      (hz_bubble)
    );

    // id_ex allocations:
    always @(posedge clk) begin
        if (rst) begin
            id_ex_valid <= 1'b0;
        end
        else if (pipe_en) begin
            // occurs on load->use stall, or redirect
            if (ex_bubble) begin
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
                id_ex_b_p       <= b_p;
            end
        end
    end

    // PIPELINE EX STAGE================================================================================

    // ex_mem_regs
    reg [31:0] ex_mem_pc;
    reg [31:0] ex_mem_instr;
    reg [31:0] ex_mem_alu_result;
    reg [31:0] ex_mem_rs2_data;
    reg [31:0] ex_mem_wb_data;
    reg [4:0]  ex_mem_rs2_addr;
    reg [4:0]  ex_mem_rd_addr;
    reg [2:0]  ex_mem_funct3;
    reg [1:0]  ex_mem_wb_src;
    reg        ex_mem_reg_write;
    reg        ex_mem_mem_read;
    reg        ex_mem_mem_write;
    reg        ex_mem_valid;

    // mem_wb_regs
    reg [31:0] mem_wb_pc;
    reg [31:0] mem_wb_instr;
    reg [31:0] mem_wb_wb_data;
    reg [4:0]  mem_wb_rd_addr;
    reg [2:0]  mem_wb_funct3;
    reg [1:0]  mem_wb_wb_src;
    reg        mem_wb_reg_write;
    reg        mem_wb_mem_read;
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
    // store data must be the forwarded ex_rs2 value
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
    wire        bc_beq     = (funct3 == `BEQ_FUNCT3)  && (ex_rs1_val == ex_rs2_val);
    wire        bc_bne     = (funct3 == `BNE_FUNCT3)  && (ex_rs1_val != ex_rs2_val);
    wire        bc_blt     = (funct3 == `BLT_FUNCT3)  && ($signed(ex_rs1_val) < $signed(ex_rs2_val));
    wire        bc_bge     = (funct3 == `BGE_FUNCT3)  && ($signed(ex_rs1_val) >= $signed(ex_rs2_val));
    wire        bc_bltu    = (funct3 == `BLTU_FUNCT3)  && (ex_rs1_val < ex_rs2_val);
    wire        bc_bgeu    = (funct3 == `BGEU_FUNCT3)  && (ex_rs1_val >= ex_rs2_val);

    // branch / jump indicators
    wire any_branch =   bc_beq
                    ||  bc_bne 
                    ||  bc_blt
                    ||  bc_bltu
                    ||  bc_bge
                    ||  bc_bgeu;
    wire take_branch = id_ex_branch && any_branch;

    // next-PC mux
    wire [31:0] pc_target   = id_ex_pc + id_ex_imm;      // branch immB
    // own adder: through the ALU, the target also waited on its shifter and result mux
    wire [31:0] jalr_sum    = ex_rs1_val + id_ex_imm;
    wire [31:0] jalr_target = {jalr_sum[31:1], 1'b0};    // rs1 + immI, bit 0 cleared (jalr)

    // jal was taken in ID; here we fix branch mispredicts (either direction) and resolve jalr
    wire br_mispredict = id_ex_branch && (take_branch != id_ex_b_p);
    assign redirect    = id_ex_valid && (br_mispredict || id_ex_jalr); // need id_ex valid so bubble doesnt count as redirect

    // next_pc for both outcomes of the compare, which arrives last (from load
    // data forwarded out of WB), so it only drives the final 2:1 mux into the
    // I-cache address.  Same result as "redirect ? redirect target : fetch_pc";
    // for a non-branch both halves are equal.  `keep` stops Quartus merging
    // the halves back into one deep function of the compare.
    wire redirect_t = id_ex_valid && (id_ex_jalr || (id_ex_branch && !id_ex_b_p));
    wire redirect_n = id_ex_valid && (id_ex_jalr || (id_ex_branch &&  id_ex_b_p));
    (* keep *) wire [31:0] next_pc_t = !redirect_t ? fetch_pc : id_ex_jalr ? jalr_target : pc_target;
    (* keep *) wire [31:0] next_pc_n = !redirect_n ? fetch_pc : id_ex_jalr ? jalr_target : id_ex_pc + 32'd4;
    assign next_pc = any_branch ? next_pc_t : next_pc_n;

    // train on every real conditional branch
    assign bp_upd_valid = id_ex_valid && id_ex_branch;
    assign bp_upd_taken = take_branch;


    //ex_mem allocations:
    always @(posedge clk) begin
        if (rst) begin
            ex_mem_valid <= 1'b0;
        end
        else if (pipe_en) begin
            ex_mem_valid        <= id_ex_valid;
            ex_mem_pc           <= id_ex_pc;
            ex_mem_instr        <= id_ex_instr;
            ex_mem_alu_result   <= alu_result;
            ex_mem_wb_data      <= ex_wb_data;
            ex_mem_rs2_data     <= ex_rs2_val;
            ex_mem_rs2_addr     <= id_ex_rs2_addr; 
            ex_mem_rd_addr      <= id_ex_rd_addr;
            ex_mem_wb_src       <= id_ex_wb_src;
            ex_mem_reg_write    <= id_ex_reg_write;
            ex_mem_mem_read     <= id_ex_mem_read;
            ex_mem_mem_write    <= id_ex_mem_write;
        end
    end

    // PIPELINE MEM STAGE================================================================================
    // Data cache
    // The address is latched at the end of this cycle and load_data is presented
    // during the NEXT cycle (the load's WB stage), so load_data is consumed in
    // WB directly instead of being copied into mem_wb.  The tag was read a
    // cycle earlier (from the EX alu_result), so a miss freezes before then.
    wire [31:0] load_data, mem_store_data;
    wire        load_store_mem_fwd;

    // djeffrey load->store forwarding, if prev cycle was valid read and rdaddr == rs2addr, store the data we just loaded
    assign load_store_mem_fwd = mem_wb_mem_read
                                && mem_wb_valid
                                && mem_wb_rd_addr != 5'd0
                                && (mem_wb_rd_addr == ex_mem_rs2_addr);
    assign mem_store_data = load_store_mem_fwd ? load_data : ex_mem_rs2_data;

    wire         dc_req, dc_we, dc_ack;
    wire [17:0]  dc_addr;
    wire [127:0] dc_wdata;

    dcache #(
        .CLEAR_SRAM (CLEAR_SRAM)
    ) u_dcache (
        .clk          (clk),
        .rst          (rst),
        .pipe_en      (pipe_en),
        .ex_addr      (alu_result),         // tag lookup for the access entering MEM
        .valid        (ex_mem_valid),
        .addr         (ex_mem_alu_result),  // read addr for load, store computed from alu
        .funct3       (ex_mem_instr[14:12]),
        .mem_read     (ex_mem_mem_read),
        .mem_write    (ex_mem_mem_write),
        .wdata        (mem_store_data),
        .rdata        (load_data),
        .busy         (dc_busy),
        .ready        (dbg_mem_ready),
        .mreq         (dc_req),
        .mwe          (dc_we),
        .maddr        (dc_addr),
        .mwdata       (dc_wdata),
        .mrdata       (mem_rdata),
        .mack         (dc_ack),
        .ev_miss      (dbg_dmiss),
        .ev_writeback (dbg_dwriteback)
    );

    // MEMORY SYS both caches share the SRAM, one 16-byte line at a time
    wire         sr_req, sr_we, sr_ack;
    wire [31:0]  sr_addr;
    wire [127:0] sr_wdata;

    // data region is upper 256 KB, instr region is lower 256 KB
    mem_arbiter u_arb (
        .clk     (clk),
        .rst     (rst),
        .d_req   (dc_req),
        .d_we    (dc_we),
        .d_addr  ({1'b1, dc_addr}),
        .d_wdata (dc_wdata),
        .d_ack   (dc_ack),
        .i_req   (ic_req),
        .i_addr  ({1'b0, ic_addr}),
        .i_ack   (ic_ack),
        .req     (sr_req),
        .we      (sr_we),
        .addr    (sr_addr),
        .wdata   (sr_wdata),
        .ack     (sr_ack)
    );

    sram_ctl u_sram (
        .clk       (clk),
        .rst       (rst),
        .req       (sr_req),
        .we        (sr_we),
        .addr      (sr_addr),
        .wdata     (sr_wdata),
        .rdata     (mem_rdata),
        .ack       (sr_ack),
        .SRAM_ADDR (SRAM_ADDR),
        .SRAM_DQ   (SRAM_DQ),
        .SRAM_CE_N (SRAM_CE_N),
        .SRAM_OE_N (SRAM_OE_N),
        .SRAM_WE_N (SRAM_WE_N),
        .SRAM_UB_N (SRAM_UB_N),
        .SRAM_LB_N (SRAM_LB_N)
    );

    //mem_wb allocations:
    always @(posedge clk) begin
        if (rst) begin
            mem_wb_valid        <= 1'b0;
        end
        else if (pipe_en) begin
            mem_wb_valid        <= ex_mem_valid;
            mem_wb_pc           <= ex_mem_pc;
            mem_wb_instr        <= ex_mem_instr;
            mem_wb_wb_data      <= ex_mem_wb_data;
            mem_wb_rd_addr      <= ex_mem_rd_addr;
            mem_wb_wb_src       <= ex_mem_wb_src;
            mem_wb_reg_write    <= ex_mem_reg_write;
            mem_wb_mem_read     <= ex_mem_mem_read; //prob dont need
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

    // events count only on edges where the pipeline moves (a frozen cycle repeats them)
    assign dbg_if_pc        = if_id_pc;
    assign dbg_retire_valid = mem_wb_valid && pipe_en;
    assign dbg_stall        = lu_stall && pipe_en;
    assign dbg_redirect     = redirect && pipe_en;

endmodule
