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
    localparam S_INIT  = 4'd0, S_IDLE  = 4'd1, S_WBRD = 4'd3,
               S_FILL  = 4'd5, S_DONE = 4'd8;
    reg [3:0]          state;
    // used during init phase to sweep cache and SRAM
    reg [CNT_BITS-1:0] cnt;
    reg [IDX_BITS-1:0] m_idx;
    reg [TAG_BITS-1:0] m_tag, v_tag;
    // write-back buffer: a dirty victim waits here while its replacement is fetched, then
    // goes to SRAM in the background. A miss waits for it to drain, so it can't re-fetch
    // the victim's line from SRAM before the victim gets there
    reg [127:0]                 line_buf;
    reg [TAG_BITS+IDX_BITS-1:0] wb_line;    // {tag, index} of the buffered victim
    reg                         wb_pending;
    wire                        wb_go = wb_pending && (state == S_IDLE || state == S_DONE);

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
    assign ev_miss = (state == S_IDLE) && access && !hit && !wb_pending;

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

    // the line arrives from sram_ctl on mack and goes straight into the data ram, its tag
    // and valid bit with it, so a half-written line is never valid
    wire fill_we = (state == S_FILL) && mack;

    // tag and valid bit sdp ram
    wire tag_we = (state == S_INIT) || fill_we;
    sdp_ram #(.AW(IDX_BITS), .DW(TAG_BITS + 1)) u_tag (
        .clk   (clk),
        .we    (tag_we),
        .waddr ((state == S_INIT) ? cnt[IDX_BITS-1:0] : m_idx),
        .wdata ((state == S_INIT) ? {(TAG_BITS+1){1'b0}} : {1'b1, m_tag}),
        .re    (pipe_en),
        .raddr (ex_addr[IDX_BITS+3:4]),
        .rdata (tagv)
    );

    // dirty bit sdp ram, read a stage early like the tag, so a miss knows at once whether
    // its victim is dirty. A store hit just ahead to the same line sets the bit on the same
    // edge the read happens: dirty_byp catches that one
    wire dirty_q;
    reg  dirty_byp;
    wire [IDX_BITS-1:0] ex_idx = ex_addr[IDX_BITS+3:4];
    sdp_ram #(.AW(IDX_BITS), .DW(1)) u_dirty (
        .clk   (clk),
        .we    (st_we || tag_we),
        .waddr (st_we ? idx : (state == S_INIT) ? cnt[IDX_BITS-1:0] : m_idx),
        .wdata (st_we),
        .re    (pipe_en),
        .raddr (ex_idx),
        .rdata (dirty_q)
    );
    always @(posedge clk)
        if (pipe_en) dirty_byp <= st_we && (idx == ex_idx);

    // data ram organized as 4 lanes of 8-bit tdp rams. Port B is 32 bits wide, lane k's
    // byte of each of the line's 4 words, so a whole line moves through it in one cycle
    wire [31:0]  word_r;
    wire [127:0] line_b;                 // the line port B read, in line order
    genvar k, w;
    generate
        for (k = 0; k < 4; k = k + 1) begin : lane
            wire [31:0] wb_k, rb_k;
            for (w = 0; w < 4; w = w + 1) begin : wd
                assign wb_k[8*w +: 8]          = mrdata[32*w + 8*k +: 8];
                assign line_b[32*w + 8*k +: 8] = rb_k[8*w +: 8];
            end
            tdp_ram #(.AW(IDX_BITS + 2), .DW(8), .RW(2)) u_lane (
                .clk     (clk),
                .en_a    (pipe_en),
                .we_a    (st_we && st_be[k]),
                .addr_a  (addr[IDX_BITS+3:2]),
                .wdata_a (st_wdata[8*k +: 8]),
                .rdata_a (word_r[8*k +: 8]),
                .we_b    (fill_we),
                .addr_b  ((state == S_IDLE) ? idx : m_idx),
                .wdata_b (wb_k),
                .rdata_b (rb_k)
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
    assign mreq   = (state == S_INIT && CLEAR_SRAM != 0) || (state == S_FILL) || wb_go;
    assign mwe    = (state != S_FILL);
    assign maddr  = (state == S_INIT) ? {{(REGION-CNT_BITS){1'b0}}, cnt} << 4
                  : (state == S_FILL) ? {m_tag, m_idx, 4'b0}
                  :                     {wb_line, 4'b0};
    assign mwdata = (state == S_INIT) ? 128'd0 : line_buf;

    assign ev_writeback = ev_miss && tagv[TAG_BITS] && (dirty_q || dirty_byp);

    // controller
    // miss -> (park a dirty victim in the write-back buffer) -> fetch the line, written in
    // with its tag on the ack -> DONE holds `filled` until the pipeline moves the access on;
    // the buffer drains to SRAM in the background
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_INIT;
            cnt        <= {CNT_BITS{1'b0}};
            wb_pending <= 1'b0;
        end else begin
            if (wb_go && mack) wb_pending <= 1'b0;
            case (state)
                // Sweep cache and SRAM (if clear) setting everything to 0 on reset, mark all lines
                // invalid and clear dirty bits, can only leave this state once cnt wraps 
                S_INIT:   if (CLEAR_SRAM == 0 || mack) begin
                              cnt <= cnt + 1'b1;
                              if (&cnt) state <= S_IDLE;
                          end
                // on a miss (access && !hit) busy freezes the pipeline; a dirty victim is read
                // out first, else fetch the new line
                S_IDLE:   if (ev_miss) begin
                              m_idx <= idx;
                              m_tag <= tag;
                              v_tag <= tagv[TAG_BITS-1:0];
                              state <= ev_writeback ? S_WBRD : S_FILL;
                          end
                // port B read the victim line on the edge into S_WBRD (addressed by the missing
                // access's index while IDLE): park it in the write-back buffer, fetch the new line
                S_WBRD:   begin
                              line_buf   <= line_b;
                              wb_line    <= {v_tag, m_idx};
                              wb_pending <= 1'b1;
                              state      <= S_FILL;
                          end
                // When we receive mem ack from sram ->arb->dcache, the line on mrdata is written
                // into the data ram with its tag (fill_we) on this edge
                S_FILL:   if (mack) state <= S_DONE;
                // hold the filled line until the pipeline moves on, then go back to S_IDLE
                default:  if (pipe_en) state <= S_IDLE;   // S_DONE
            endcase
        end
    end
endmodule
