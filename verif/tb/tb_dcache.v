`timescale 1ns/1ps

// Unit test for dcache.v: thousands of random loads and stores, driven the way
// the pipeline drives them (tag lookup from the EX address, the access in MEM,
// load data in WB, everything held while pipe_en is low), checked against a
// byte-level reference memory.  Addresses crowd onto a few cache lines with
// every possible tag, so nearly every access misses and most evictions are
// dirty; clk_en is random.  At the end every byte of the region is compared,
// read through the cache where a line is present, else from the SRAM model.
//
// Two rigs run side by side:
//   sim   the pipeline's configuration (16 KB cache, 256 KB region), SRAM
//         model zeroed at power-up
//   board CLEAR_SRAM=1 on an SRAM model that powers up as X: proves the reset
//         sweep zeroes the whole region (smaller sizes so the sweep is short)
module tb_dcache;
    reg clk = 0;
    always #5 clk = ~clk;

    wire done_a, done_b;
    wire [31:0] err_a, err_b;

    dcache_rig #(.IDX_BITS(10), .REGION(18), .CLEAR_SRAM(0), .ZERO_INIT(1), .SEED(11), .NOPS(30000))
        sim   (.clk(clk), .done(done_a), .errors(err_a));
    dcache_rig #(.IDX_BITS(6),  .REGION(14), .CLEAR_SRAM(1), .ZERO_INIT(0), .SEED(23), .NOPS(20000))
        board (.clk(clk), .done(done_b), .errors(err_b));

    initial begin
        wait (done_a && done_b);
        if (err_a == 0 && err_b == 0) $display("PASSED");
        else $display("FAIL: %0d error(s) in the sim rig, %0d in the board rig", err_a, err_b);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: timeout (a miss never completed?)");
        $finish;
    end
endmodule

module dcache_rig #(
    parameter IDX_BITS   = 10,
    parameter REGION     = 18,
    parameter CLEAR_SRAM = 0,
    parameter ZERO_INIT  = 1,
    parameter SEED       = 1,
    parameter NOPS       = 10000
) (
    input  wire        clk,
    output reg         done,
    output reg  [31:0] errors
);
    localparam TAG_BITS = REGION - IDX_BITS - 4;
    localparam BYTES    = 1 << REGION;

    reg rst = 1;
    reg clk_en = 1;

    // ---- the pipeline's view: EX -> MEM -> WB --------------------------------
    reg        ex_v = 0, mem_v = 0, wb_v = 0;
    reg [31:0] ex_a = 0, mem_a = 0, wb_a = 0;
    reg [2:0]  ex_f3 = 0, mem_f3 = 0, wb_f3 = 0;
    reg        ex_ld = 0, ex_st = 0, mem_ld = 0, mem_st = 0, wb_ld = 0;
    reg [31:0] ex_d = 0, mem_d = 0, wb_exp = 0;
    integer    advanced = 0;            // edges on which the pipeline moved

    wire [31:0] rdata;
    wire        busy, ready;
    wire        pipe_en = clk_en && !busy;

    wire               mreq, mwe, mack, ev_miss, ev_wb;
    wire [REGION-1:0]  maddr;
    wire [127:0]       mwdata, mrdata;
    wire               sr_req, sr_we, sr_ack;
    wire [31:0]        sr_addr;
    wire [127:0]       sr_wdata;
    wire [REGION-2:0]  SRAM_ADDR;
    wire [15:0]        SRAM_DQ;
    wire               SRAM_CE_N, SRAM_OE_N, SRAM_WE_N, SRAM_UB_N, SRAM_LB_N;

    dcache #(.IDX_BITS(IDX_BITS), .REGION(REGION), .CLEAR_SRAM(CLEAR_SRAM)) dut (
        .clk (clk), .rst (rst), .pipe_en (pipe_en), .ex_addr (ex_a),
        .valid (mem_v), .addr (mem_a), .funct3 (mem_f3), .mem_read (mem_ld), .mem_write (mem_st),
        .wdata (mem_d), .rdata (rdata), .busy (busy), .ready (ready),
        .mreq (mreq), .mwe (mwe), .maddr (maddr), .mwdata (mwdata), .mrdata (mrdata), .mack (mack),
        .ev_miss (ev_miss), .ev_writeback (ev_wb)
    );

    // the instruction port stays idle; the region sits at SRAM address 0
    mem_arbiter #(.AW(REGION)) u_arb (
        .clk (clk), .rst (rst),
        .d_req (mreq), .d_we (mwe), .d_addr (maddr), .d_wdata (mwdata), .d_ack (mack),
        .i_req (1'b0), .i_addr ({REGION{1'b0}}), .i_ack (),
        .req (sr_req), .we (sr_we), .addr (sr_addr), .wdata (sr_wdata), .ack (sr_ack)
    );

    sram_ctl #(.ADDR_BITS(REGION)) u_ctl (
        .clk (clk), .rst (rst), .req (sr_req), .we (sr_we), .addr (sr_addr), .wdata (sr_wdata),
        .rdata (mrdata), .ack (sr_ack),
        .SRAM_ADDR (SRAM_ADDR), .SRAM_DQ (SRAM_DQ), .SRAM_CE_N (SRAM_CE_N), .SRAM_OE_N (SRAM_OE_N),
        .SRAM_WE_N (SRAM_WE_N), .SRAM_UB_N (SRAM_UB_N), .SRAM_LB_N (SRAM_LB_N)
    );

    sram_model #(.ABITS(REGION-1), .ZERO_INIT(ZERO_INIT)) u_sram (
        .SRAM_ADDR (SRAM_ADDR), .SRAM_DQ (SRAM_DQ), .SRAM_CE_N (SRAM_CE_N), .SRAM_OE_N (SRAM_OE_N),
        .SRAM_WE_N (SRAM_WE_N), .SRAM_UB_N (SRAM_UB_N), .SRAM_LB_N (SRAM_LB_N)
    );

    // ---- reference memory ------------------------------------------------------
    reg [7:0] model [0:BYTES-1];
    integer i;
    initial for (i = 0; i < BYTES; i = i + 1) model[i] = 8'd0;

    function [31:0] load_value(input [2:0] f3, input [31:0] a);
        reg [REGION-1:0] b;
        reg [31:0] w;
        begin
            b = {a[REGION-1:2], 2'b00};
            w = {model[b+3], model[b+2], model[b+1], model[b]};
            case (f3)
                3'b000: load_value = {{24{w[8*a[1:0]+7]}}, w[8*a[1:0] +: 8]};
                3'b001: load_value = {{16{w[16*a[1]+15]}}, w[16*a[1] +: 16]};
                3'b100: load_value = {24'd0, w[8*a[1:0] +: 8]};
                3'b101: load_value = {16'd0, w[16*a[1] +: 16]};
                default: load_value = w;
            endcase
        end
    endfunction

    task store_value(input [2:0] f3, input [31:0] a, input [31:0] d);
        reg [REGION-1:0] b;
        begin
            b = a[REGION-1:0];
            model[b] = d[7:0];
            if (f3 != 3'b000) model[b+1] = d[15:8];
            if (f3 == 3'b010) begin model[b+2] = d[23:16]; model[b+3] = d[31:24]; end
        end
    endtask

    // ---- random accesses: a few lines, every tag, sometimes past the region ---
    integer seed = SEED, issued = 0, misses = 0, writebacks = 0;
    reg [31:0] r, a;
    reg [IDX_BITS-1:0] idx;
    reg [2:0] f3;

    task next_op;
        begin
            r = $random(seed);
            case (r[1:0])
                2'd0: idx = 0;
                2'd1: idx = 1;
                2'd2: idx = {IDX_BITS{1'b1}};
                default: idx = r[IDX_BITS+11:12];
            endcase
            a = {$random(seed)} & ~32'hF;
            a[IDX_BITS+3:4] = idx;
            if (r[6:4] != 0) a = a & ((1 << REGION) - 1);   // 1 in 8 wraps around the region
            if (r[9:7] < 2) begin
                ex_v <= 1'b0;                                // bubble
            end else if (r[9:7] < 5) begin
                case (r[12:10] % 5)
                    0: f3 = 3'b000; 1: f3 = 3'b001; 2: f3 = 3'b010; 3: f3 = 3'b100; default: f3 = 3'b101;
                endcase
                ex_v <= 1'b1; ex_ld <= 1'b1; ex_st <= 1'b0; ex_f3 <= f3;
                ex_a <= a | (r[16:13] & (f3[1:0] == 2'b00 ? 4'hF : f3[1:0] == 2'b01 ? 4'hE : 4'hC));
                issued = issued + 1;
            end else begin
                f3 = r[18:17] == 0 ? 3'b000 : r[18:17] == 1 ? 3'b001 : 3'b010;
                ex_v <= 1'b1; ex_ld <= 1'b0; ex_st <= 1'b1; ex_f3 <= f3; ex_d <= $random(seed);
                ex_a <= a | (r[16:13] & (f3 == 3'b000 ? 4'hF : f3 == 3'b001 ? 4'hE : 4'hC));
                issued = issued + 1;
            end
        end
    endtask

    // clk_en for the next edge is chosen half a cycle ahead
    always @(negedge clk) clk_en = ($random(seed) % 4) != 0;

    always @(posedge clk) begin
        if (ev_miss) misses = misses + 1;
        if (ev_wb)   writebacks = writebacks + 1;
        if (!rst && pipe_en) begin
            advanced = advanced + 1;
            if (wb_v && wb_ld && rdata !== wb_exp) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("FAIL %m: load f3=%0d @%08x returned %08x, expected %08x",
                             wb_f3, wb_a, rdata, wb_exp);
            end
            if (mem_v && mem_st) store_value(mem_f3, mem_a, mem_d);
            wb_exp <= (mem_v && mem_ld) ? load_value(mem_f3, mem_a) : 32'd0;
            wb_v   <= mem_v;   wb_ld  <= mem_ld; wb_f3 <= mem_f3; wb_a <= mem_a;
            mem_v  <= ex_v;    mem_a  <= ex_a;   mem_f3 <= ex_f3; mem_ld <= ex_ld; mem_st <= ex_st; mem_d <= ex_d;
            if (issued < NOPS) next_op;
            else               ex_v <= 1'b0;
        end
    end

    // ---- final check: every byte, through the cache where its line is present -
    reg [TAG_BITS:0] tv;
    reg [7:0]        got;
    integer          bad, drained;
    initial begin
        done = 0;
        errors = 0;
        repeat (3) @(posedge clk);
        rst <= 0;
        wait (issued >= NOPS);
        drained = advanced + 4;             // bubbles push the last access out of WB
        wait (advanced >= drained);
        @(negedge clk);
        bad = 0;
        for (i = 0; i < BYTES; i = i + 1) begin
            tv = dut.u_tag.mem[i[IDX_BITS+3:4]];
            if (tv[TAG_BITS] && tv[TAG_BITS-1:0] == i[REGION-1:IDX_BITS+4])
                case (i[1:0])
                    0: got = dut.lane[0].u_lane.mem[i[IDX_BITS+3:2]];
                    1: got = dut.lane[1].u_lane.mem[i[IDX_BITS+3:2]];
                    2: got = dut.lane[2].u_lane.mem[i[IDX_BITS+3:2]];
                    default: got = dut.lane[3].u_lane.mem[i[IDX_BITS+3:2]];
                endcase
            else
                got = i[0] ? u_sram.mem[i >> 1][15:8] : u_sram.mem[i >> 1][7:0];
            if (got !== model[i]) begin
                bad = bad + 1;
                if (bad <= 5) $display("FAIL %m: final byte %05x is %02x, expected %02x", i, got, model[i]);
            end
        end
        errors = errors + bad + u_sram.errors;
        if (u_sram.errors) $display("FAIL %m: SRAM model saw %0d timing violation(s)", u_sram.errors);
        $display("%m: %0d accesses, %0d misses, %0d dirty write-backs, %0d errors",
                 issued, misses, writebacks, errors);
        done = 1;
    end
endmodule
