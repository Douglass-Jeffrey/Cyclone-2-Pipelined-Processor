`timescale 1ns/1ps

// Behavioural model of the DE1's asynchronous SRAM chip (IS61LV25616: 256K x
// 16, active-low CE/OE/WE/UB/LB), shared by every testbench that talks to the
// SRAM.  It checks the timing any async SRAM depends on, so a controller that
// only works in zero-delay simulation fails here instead of on the board.
//
//   reads   DQ is X until the address has been stable for T_ACC and OE_N
//           low for T_OE, so sampling too early reads X
//   writes  commit on WE_N rising (the standard WE-controlled write).  It is
//           an error for the address to change while WE_N is low or on the
//           same instant WE_N falls or rises, for write data to change on the
//           instant WE_N rises or be X/Z then, or for the pulse to be shorter
//           than T_WP
//   bus     anything else driving DQ while the chip drives it is an error
//
// `errors` counts every violation; a testbench reads it at the end.
// STUCK_ADDR_BIT / STUCK_DQ_BIT >= 0 hold that address / data bit at 0: a
// fault for proving that a memory test notices one.
module sram_model #(
    parameter ABITS          = 18,  // word address bits (18: 256K words, 512 KB)
    parameter T_ACC          = 15,  // ns, address stable to data valid (covers -10 and -12 parts)
    parameter T_OE           = 10,  // ns, OE_N low to data valid
    parameter T_WP           = 10,  // ns, shortest WE_N low pulse accepted
    parameter ZERO_INIT      = 0,   // 1: power up zeroed (to match a reference model); 0: X, like the chip
    parameter STUCK_ADDR_BIT = -1,
    parameter STUCK_DQ_BIT   = -1
) (
    input  wire [ABITS-1:0] SRAM_ADDR,
    inout  wire [15:0]      SRAM_DQ,
    input  wire             SRAM_CE_N,
    input  wire             SRAM_OE_N,
    input  wire             SRAM_WE_N,
    input  wire             SRAM_UB_N,
    input  wire             SRAM_LB_N
);
    reg [15:0] mem [0:(1<<ABITS)-1];
    integer errors = 0;
    integer i;
    initial if (ZERO_INIT) for (i = 0; i < (1<<ABITS); i = i + 1) mem[i] = 16'h0;

    // fault injection: which slot an address really reaches, which bits stick
    localparam [ABITS-1:0] AMASK = (STUCK_ADDR_BIT >= 0) ? ~({{(ABITS-1){1'b0}}, 1'b1} << STUCK_ADDR_BIT)
                                                         : {ABITS{1'b1}};
    localparam [15:0]      DMASK = (STUCK_DQ_BIT >= 0) ? ~(16'h1 << STUCK_DQ_BIT) : 16'hFFFF;
    wire [ABITS-1:0] slot = SRAM_ADDR & AMASK;

    task fail(input [8*64-1:0] msg);
        begin
            errors = errors + 1;
            if (errors <= 10) $display("SRAM MODEL ERROR @ %0t: %0s", $time, msg);
        end
    endtask

    // ---- read: inertial delays follow only once the input has been stable ----
    wire [ABITS-1:0] addr_seen;
    wire             oe_seen_n;
    assign #(T_ACC) addr_seen = SRAM_ADDR;
    assign #(T_OE)  oe_seen_n = SRAM_OE_N;

    wire        reading = !SRAM_CE_N && !SRAM_OE_N && SRAM_WE_N;
    wire        settled = (addr_seen === SRAM_ADDR) && (oe_seen_n === 1'b0);
    wire [15:0] q       = settled ? (mem[slot] & DMASK) : 16'hxxxx;
    assign SRAM_DQ[15:8] = (reading && !SRAM_UB_N) ? q[15:8] : 8'bz;
    assign SRAM_DQ[7:0]  = (reading && !SRAM_LB_N) ? q[7:0]  : 8'bz;

    // a second driver shows up as DQ differing from what the chip drives
    always @(SRAM_DQ or reading or q) #0.001
        if (reading && !SRAM_UB_N && !SRAM_LB_N && SRAM_DQ !== q) fail("bus contention on DQ");

    // ---- write timing ----
    realtime t_addr = 0, t_dq = 0, t_we_fall = 0, t_we_rise = -1;

    always @(SRAM_ADDR) begin
        if (SRAM_CE_N === 1'b0 && SRAM_WE_N === 1'b0) fail("address changed during a write pulse");
        if (SRAM_CE_N === 1'b0 && $realtime == t_we_rise) fail("address changed as WE_N rose (no hold)");
        t_addr = $realtime;
    end

    always @(SRAM_DQ) begin
        if (SRAM_CE_N === 1'b0 && $realtime == t_we_rise) fail("write data changed as WE_N rose (no hold)");
        t_dq = $realtime;
    end

    always @(negedge SRAM_WE_N) if (SRAM_CE_N === 1'b0) begin
        if (t_addr == $realtime) fail("address changed as WE_N fell (no setup)");
        t_we_fall = $realtime;
    end

    always @(posedge SRAM_WE_N) if (SRAM_CE_N === 1'b0) begin
        t_we_rise = $realtime;
        if ($realtime - t_we_fall < T_WP) fail("WE_N pulse too short");
        if (t_addr == $realtime)          fail("address changed as WE_N rose (no hold)");
        if (t_dq == $realtime)            fail("write data changed as WE_N rose (no hold)");
        if (^SRAM_DQ === 1'bx)            fail("write data X or Z as WE_N rose");
        mem[slot] <= {SRAM_UB_N ? mem[slot][15:8] : SRAM_DQ[15:8] & DMASK[15:8],
                      SRAM_LB_N ? mem[slot][7:0]  : SRAM_DQ[7:0]  & DMASK[7:0]};
    end
endmodule
