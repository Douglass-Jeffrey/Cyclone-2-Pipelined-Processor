// 16 KB direct-mapped write-back data cache, 16-byte lines, in front of the
// SRAM's data region.
// Cache hits behaves exactly like previous dmem, store in MEM, load data in WB.
//
// Tag gets read a stage early, addressed by the EX-stage ALU result, so a miss
// is known in MEM and `busy` freezes the pipeline before the store or load completes.
//
// CLEAR_SRAM=1 zeroes the whole data region at reset, so the board starts from all 0 mem.
`include "defines.vh"

module dcache #(
    parameter IDX_BITS   = 10,          // 1024 lines x 16 B = 16 KB
    parameter REGION     = 18,          // byte-address bits of the data region (256 KB)
    parameter CLEAR_SRAM = 0
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              pipe_en,
    // ALU result, for the cycle early tag lookup (EX)
    input  wire [31:0]       ex_addr,
    // PORT A, pipeline regs <-> Dcache I/O
    // in from pipeline regs
    input  wire              valid,
    input  wire [31:0]       addr,
    input  wire [2:0]        funct3,
    input  wire              mem_read,
    input  wire              mem_write,
    input  wire [31:0]       wdata,
    // out to pipeline regs
    // sign/zero-extended load result (WB)
    output reg  [31:0]       rdata,
    // freeze pipeline for waits on sram memory (MEM), or post reset memory sweep
    output wire              busy,
    // reset sweep finished
    output wire              ready,
    // PORT B, Dcache <-> Arbiter bus line I/O
    // in from mem_arbiter
    input  wire              mack,
    // Out to mem_arbiter
    output wire              mreq,
    output wire              mwe,
    output wire [REGION-1:0] maddr,
    output wire [127:0]      mwdata,
    // in from sram_ctl
    input  wire [127:0]      mrdata,
    // output debug
    output wire              ev_miss,
    output wire              ev_writeback
);

    // 2^18 SRAM B, 2^10 lines, 2^4 B per line, so TAG_BITS = 2^4, 16 possible lines in sram per cache line
    localparam TAG_BITS = REGION - IDX_BITS - 4;
    // If CLEAR_SRAM, reset zeros whole SRAM data region, else just wipe the cache tags and dirty bits
    localparam CNT_BITS = CLEAR_SRAM ? REGION - 4 : IDX_BITS;

    // FSM states for cache ctl.
    localparam S_INIT  = 4'd0, S_IDLE  = 4'd1, S_CHECK = 4'd2, S_WBRD = 4'd3, S_WBREQ = 4'd4,
               S_FILL  = 4'd5, S_FILLWR = 4'd6, S_TAG  = 4'd7, S_DONE = 4'd8;
    reg [3:0]          state;
    // used during init phase to sweep cache and SRAM
    reg [CNT_BITS-1:0] cnt;
    reg [IDX_BITS-1:0] m_idx;
    reg [TAG_BITS-1:0] m_tag, v_tag;
    reg                v_valid;
    reg [2:0]          wcnt;
    reg [127:0]        line_buf;

    wire [IDX_BITS-1:0] idx = addr[IDX_BITS+3:4];
    wire [TAG_BITS-1:0] tag = addr[REGION-1:IDX_BITS+4];

    // hit
    // Organized as {valid, tag} of addr's line, read when it left EX
    wire [TAG_BITS:0] tagv;
    wire tag_hit = tagv[TAG_BITS] && (tagv[TAG_BITS-1:0] == tag);
    wire access  = valid && (mem_read || mem_write);
    wire filled  = (state == S_DONE);
    wire hit     = tag_hit || filled;

    assign ready   = (state != S_INIT);
    assign busy    = !ready || (access && !hit);
    assign ev_miss = (state == S_IDLE) && access && !hit;

    // store alignment with byte enable
    reg [31:0] st_wdata;
    reg [3:0]  st_be;
    always @(*) begin
        case (funct3)
            `SB_FUNCT3: begin
                st_wdata = {4{wdata[7:0]}};
                st_be = 4'b0001 << addr[1:0];
            end // SB
            `SH_FUNCT3: begin
                st_wdata = {2{wdata[15:0]}};
                st_be = 4'b0011 << addr[1:0];
            end // SH
            `SW_FUNCT3: begin
                st_wdata = wdata;
                st_be = 4'b1111;
            end // SW
            default: begin
                st_wdata = wdata;
                st_be = 4'b0000;
            end
        endcase
    end
    wire st_we = pipe_en && valid && mem_write && hit;

    // tag and valid bit sdp ram
    wire tag_we = (state == S_INIT) || (state == S_TAG);
    sdp_ram #(.AW(IDX_BITS), .DW(TAG_BITS + 1)) u_tag (
        .clk   (clk),
        .we    (tag_we),
        .waddr ((state == S_INIT) ? cnt[IDX_BITS-1:0] : m_idx),
        .wdata ((state == S_INIT) ? {(TAG_BITS+1){1'b0}} : {1'b1, m_tag}),
        .re    (pipe_en),
        .raddr (ex_addr[IDX_BITS+3:4]),
        .rdata (tagv)
    );

    // dirty bit sdp ram 
    wire dirty_q;
    sdp_ram #(.AW(IDX_BITS), .DW(1)) u_dirty (
        .clk   (clk),
        .we    (st_we || tag_we),
        .waddr (st_we ? idx : (state == S_INIT) ? cnt[IDX_BITS-1:0] : m_idx),
        .wdata (st_we),
        .re    (1'b1),
        .raddr (idx),
        .rdata (dirty_q)
    );

    // data ram organized as 4 lanes of 8-bit tdp rams
    wire [31:0] word_r, word_b;
    wire        fill_we = (state == S_FILLWR);
    wire [31:0] fill_word = line_buf[32*wcnt[1:0] +: 32];
    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : lane
            tdp_ram #(.AW(IDX_BITS + 2), .DW(8)) u_lane (
                .clk     (clk),
                .en_a    (pipe_en),
                .we_a    (st_we && st_be[k]),
                .addr_a  (addr[IDX_BITS+3:2]),
                .wdata_a (st_wdata[8*k +: 8]),
                .rdata_a (word_r[8*k +: 8]),
                .we_b    (fill_we),
                .addr_b  ({m_idx, wcnt[1:0]}),
                .wdata_b (fill_word[8*k +: 8]),
                .rdata_b (word_b[8*k +: 8])
            );
        end
    endgenerate

    // load alignment and sign/zero ext 
    reg [2:0] funct3_r;
    reg [1:0] boff_r;
    reg       mem_read_r;
    always @(posedge clk) begin
        if (pipe_en) begin
            funct3_r   <= funct3;
            boff_r     <= addr[1:0];
            mem_read_r <= valid && mem_read;
        end
    end

    always @(*) begin
        if (!mem_read_r) begin
            rdata = 32'd0;
        end else begin
            case (funct3_r)
                `LB_FUNCT3: rdata = {{24{word_r[8*boff_r+7]}},      word_r[8*boff_r     +: 8]};  // LB
                `LH_FUNCT3: rdata = {{16{word_r[16*boff_r[1]+15]}}, word_r[16*boff_r[1] +: 16]}; // LH
                `LW_FUNCT3: rdata = word_r;                                                      // LW
                `LBU_FUNCT3: rdata = {24'b0,                     word_r[8*boff_r     +: 8]};      // LBU
                `LHU_FUNCT3: rdata = {16'b0,                     word_r[16*boff_r[1] +: 16]};     // LHU
                default: rdata = word_r;
            endcase
        end
    end

    // line bus 
    assign mreq   = (state == S_INIT && CLEAR_SRAM != 0) || (state == S_WBREQ) || (state == S_FILL);
    assign mwe    = (state != S_FILL);
    assign maddr  = (state == S_INIT)  ? {{(REGION-CNT_BITS){1'b0}}, cnt} << 4
                  : (state == S_WBREQ) ? {v_tag, m_idx, 4'b0}
                  :                      {m_tag, m_idx, 4'b0};
    assign mwdata = (state == S_INIT) ? 128'd0 : line_buf;

    assign ev_writeback = (state == S_CHECK) && v_valid && dirty_q;

    // controller
    // miss -> (write the old line back if dirty) -> fetch the line -> write it in
    // -> new tag -> DONE holds `filled` until the pipeline moves the access on
    always @(posedge clk) begin
        if (rst) begin
            state <= S_INIT;
            cnt   <= {CNT_BITS{1'b0}};
        end else begin
            case (state)
                // Sweep cache and SRAM (if clear) setting everything to 0 on reset, mark all lines
                // invalid and clear dirty bits, can only leave this state once cnt wraps 
                S_INIT:   if (CLEAR_SRAM == 0 || mack) begin
                              cnt <= cnt + 1'b1;
                              if (&cnt) state <= S_IDLE;
                          end
                // if we have a miss (access && !hit) check if victim line is dirty
                // at the same time raise the busy flag to freeze the pipeline
                S_IDLE:   if (ev_miss) begin
                              m_idx   <= idx;
                              m_tag   <= tag;
                              v_tag   <= tagv[TAG_BITS-1:0];
                              v_valid <= tagv[TAG_BITS];
                              state   <= S_CHECK;
                          end
                // check if the victim line is dirty, if so write it back, else fetch the new line
                S_CHECK:  begin 
                              wcnt  <= 3'd0;
                              state <= ev_writeback ? S_WBRD : S_FILL;
                          end
                // port B of data ram writes the victim line to the line buffer,
                // S_WBRD waits one cycle that it needs to access the data ram.
                // write one word per cycle for 4 cycles, then enter writeback request state
                S_WBRD:   begin
                              if (wcnt != 3'd0) line_buf[32*(wcnt-3'd1) +: 32] <= word_b;
                              wcnt <= wcnt + 3'd1;
                              if (wcnt == 3'd4) state <= S_WBREQ;
                          end
                // Entering S_WBREQ triggers mreq, mwe, maddr with line buffer data as mwdata
                // wait for the ack from the arbiter, then go to S_FILL to fetch the new line
                S_WBREQ:  if (mack) state <= S_FILL;
                // When we receive mem ack from sram ->arb->dcache, data comes directly from sram_ctl
                // read it into line_buffer, reset wcnt and go to S_FILLWR to write buffer to data ram
                S_FILL:   if (mack) begin
                              line_buf <= mrdata;
                              wcnt     <= 3'd0;
                              state    <= S_FILLWR;
                          end
                // write one word per cycle for 4 cycles, then enter S_TAG to write the new tag
                S_FILLWR: begin
                              wcnt <= wcnt + 3'd1;
                              if (wcnt == 3'd3) state <= S_TAG;
                          end
                // write the new tag and valid bit, then enter S_DONE to hold the filled line
                S_TAG:    state <= S_DONE;
                // hold the filled line until the pipeline moves on, then go back to S_IDLE
                default:  if (pipe_en) state <= S_IDLE;   // S_DONE
            endcase
        end
    end
endmodule
