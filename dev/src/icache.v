// 8 KB direct-mapped instruction cache, 16-byte lines, in front of the
// SRAM's code region.
// Cache hits behave exactly like the previous imem, addressed with next_pc in IF, instr out in ID.
//
// Tag gets read on the same edge as the instr, so a miss is known in ID. The pipeline then
// holds the fetch like a load-use stall (IF/ID held, bubble into EX) while the line comes in,
// and the instrs already in EX, MEM and WB keep going.
//
// WARM=1 powers up holding INIT_FILE's first 8 KB with every line valid, so a program up
// to 8 KB runs straight from the bitstream with no SRAM image.
`include "defines.vh"

module icache #(
    parameter IDX_BITS  = 9,            // 512 lines x 16 B = 8 KB
    parameter REGION    = 18,           // byte-address bits of the code region (256 KB)
    parameter INIT_FILE = "program.hex", // data ram power-up contents when WARM
    parameter WARM      = 1             // 1: every line powers up valid with tag 0
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              pipe_en,
    // PORT A, pipeline regs <-> Icache I/O
    // in from pipeline regs
    // fetch address (IF), both rams latch it on the edge
    input  wire [31:0]       next_pc,
    // pc of the instr now in ID (if_id_pc), compared against the tag
    input  wire [31:0]       pc,
    // ID holds a fetch that is still wanted (if_id_valid && !redirect)
    input  wire              fetch_req,
    // out to pipeline regs
    // instr for ID
    output wire [31:0]       instr,
    // instr is good this cycle; low stalls the front end
    output wire              hit,
    // PORT B, Icache <-> Arbiter bus line I/O (reads only, so no mwe or mwdata)
    // in from mem_arbiter
    input  wire              mack,
    // Out to mem_arbiter
    output wire              mreq,
    output wire [REGION-1:0] maddr,
    // in from sram_ctl
    input  wire [127:0]      mrdata,
    // output debug
    output wire              ev_miss
);

    // 2^18 SRAM B, 2^9 lines, 2^4 B per line, so TAG_BITS = 5, 32 possible lines in sram per cache line
    localparam TAG_BITS = REGION - IDX_BITS - 4;

    // FSM states for icache refill ctl.
    localparam S_IDLE = 3'd0, S_REQ = 3'd1, S_WRITE = 3'd2, S_TAG = 3'd3, S_DONE = 3'd4;
    reg [2:0]          state;
    // index and tag of the line being refilled, latched when the miss is seen
    reg [IDX_BITS-1:0] m_idx;
    reg [TAG_BITS-1:0] m_tag;
    // which word of the line buffer goes into the data ram this cycle (S_WRITE)
    reg [1:0]          wcnt;
    // line from sram_ctl, held while it is written into the data ram
    reg [127:0]        line_buf;

    // tag and valid bit sdp ram
    // read port: CPU, addressed by next_pc on the same edge as the data ram
    // write port: controller, clears valid when a miss starts, writes {1, tag} in S_TAG
    wire                tag_we    = (state == S_TAG) || (state == S_IDLE && ev_miss);
    wire [TAG_BITS:0]   tag_wdata = (state == S_TAG) ? {1'b1, m_tag} : {(TAG_BITS+1){1'b0}};
    wire [IDX_BITS-1:0] tag_waddr = (state == S_TAG) ? m_idx : pc[IDX_BITS+3:4];
    // Organized as {valid, tag} of the fetched line
    wire [TAG_BITS:0]   tagv;

    sdp_ram #(
        .AW         (IDX_BITS),
        .DW         (TAG_BITS + 1),
        .INIT_VALUE (WARM ? {1'b1, {TAG_BITS{1'b0}}} : {(TAG_BITS+1){1'b0}})
    ) u_tag (
        .clk   (clk),
        .we    (tag_we),
        .waddr (tag_waddr),
        .wdata (tag_wdata),
        .re    (pipe_en),
        .raddr (next_pc[IDX_BITS+3:4]),
        .rdata (tagv)
    );

    // data ram, 2048 x 32 sdp ram, one instr per entry (no byte lanes, instrs are only read whole)
    // read port: CPU, next_pc[12:2], instr arrives in ID
    // write port: controller, one word per cycle in S_WRITE
    sdp_ram #(
        .AW        (IDX_BITS + 2),
        .DW        (32),
        .INIT_FILE (WARM ? INIT_FILE : "")
    ) u_data (
        .clk   (clk),
        .we    (state == S_WRITE),
        .waddr ({m_idx, wcnt}),
        .wdata (line_buf[32*wcnt +: 32]),
        .re    (pipe_en),
        .raddr (next_pc[IDX_BITS+3:2]),
        .rdata (instr)
    );

    // hit
    // never a hit while a refill is under way: the read port may be looking
    // at the line being rewritten
    assign hit = (state == S_IDLE) && tagv[TAG_BITS] &&
                 (tagv[TAG_BITS-1:0] == pc[REGION-1:IDX_BITS+4]);

    assign ev_miss = (state == S_IDLE) && fetch_req && !hit;

    // line bus
    assign mreq    = (state == S_REQ);
    assign maddr   = {m_tag, m_idx, 4'b0};

    // controller
    // miss-> invalidate the line -> fetch it -> write it in -> new tag
    // -> DONE waits for the read port to re-read, then the held fetch hits
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                // wait for a miss on a fetch that is still wanted (ev_miss), latch the line's
                // index and tag. The same edge clears the line's valid bit (tag_we), so a reset
                // part way through a refill never leaves a valid tag over half written data
                S_IDLE:  if (ev_miss) begin
                             m_idx <= pc[IDX_BITS+3:4];
                             m_tag <= pc[REGION-1:IDX_BITS+4];
                             state <= S_REQ;
                         end
                // Entering S_REQ raises mreq with maddr = {m_tag, m_idx, 0}. When the ack comes
                // back through the arbiter, the line is on mrdata from sram_ctl: copy it into
                // line_buf, reset wcnt and go to S_WRITE
                S_REQ:   if (mack) begin
                             line_buf <= mrdata;
                             wcnt     <= 2'd0;
                             state    <= S_WRITE;
                         end
                // write one word per cycle from line_buf into the data ram for 4 cycles,
                // then enter S_TAG to write the new tag
                S_WRITE: begin
                             wcnt <= wcnt + 2'd1;
                             if (wcnt == 2'd3) state <= S_TAG;
                         end
                // write the new tag and valid bit. The data is already in, so the line only
                // becomes valid once all of it is written
                S_TAG:   state <= S_DONE;
                // hit is still forced low here. The read port only re-reads on an edge where the
                // pipeline moves (pipe_en), so wait for one then IDLE sees the new tag
                default: if (pipe_en) state <= S_IDLE;   // S_DONE
            endcase
        end
    end
endmodule
