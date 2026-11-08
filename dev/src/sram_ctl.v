// sram_ctl controller for the board's off-chip asynchronous SRAM
// (IS61LV25616AL: 256K x 16, 18-bit address, 16-bit data, active-low
// CE/OE/WE/UB/LB -- the chip on the DE1/DE2 Cyclone II boards).
//
// Moves one 16-byte line per request, shared by both caches through mem_arbiter.v,
// so neither cache sees the SRAM pins or timing. The chip's data bus is 16 bits, so
// one line (128 bits) is moved as 8 back-to-back 16-bit SRAM words ("beats").
//
// Writes, WR_FAST = 0: each beat is SETUP (1 cycle) -> PULSE (WAIT_CYCLES) -> HOLD (1 cycle),
// so address and data reach the pins a full cycle before WE_N falls and stay a full cycle
// after it rises. WR_FAST = 1: two cycles per beat, with WE_N from a falling-edge register:
// address and data change on a rising edge, WE_N falls half a cycle later and rises half a
// cycle before the next beat's address (10 ns setup, 20 ns pulse, 10 ns hold). Either way
// nothing changes on the same edge as WE_N.
// Reads are pipelined: an async SRAM needs no strobe, its data just follows the address
// while OE_N is low. Each beat's address stays on the pins RD_CYCLES cycles, the input
// register samples DQ on the edge that ends it (as the next address goes out), and the
// beat is stored a cycle later. RD_CYCLES = 1 budgets 20 ns for pin-out + the chip's
// 10 ns access + pin-in.
// Every pin comes straight from a register, so Quartus can use the I/O-cell registers
// and keep pin-to-pin skew small.
// Per line: writes (WAIT_CYCLES+2)*8 + 2 cycles (16 + 1 with WR_FAST), reads 8*RD_CYCLES + 2.

//DJEFFREY TODO, in future consider speeding up sram ops
// options to do this are
// 1. changing writeback for dirty bit behaviour, instead of doing writeback then fill
// we could copy victim cache line into buffer then fill from sram, then write buffer back after
// 2. changing port b on dcache for 1 cycle writes instead of 4 cycles for the 16 bytes
`include "defines.vh"

`timescale 1ns/1ps
module sram_ctl #(
    parameter ADDR_BITS   = 19,     // byte address space behind this controller (512KB)
    parameter WAIT_CYCLES = 2,      // write: cycles WE_N stays low per beat (>=1), WR_FAST = 0
    parameter WR_FAST     = 1,      // write: 1 = two-cycle beats, WE_N on the falling edge
    parameter RD_CYCLES   = 1       // read: cycles each beat's address is on the pins (>=1)
) (
    input  wire         clk,
    input  wire         rst,

    // line bus, mem_arbiter <-> sram_ctl
    // in from mem_arbiter
    input  wire         req,
    input  wire         we,
    input  wire [31:0]  addr,
    input  wire [127:0] wdata,
    output reg  [127:0] rdata,
    output reg          ack,
    // physical SRAM pins
    // halfword address = {line, beat}
    output reg  [ADDR_BITS-2:0] SRAM_ADDR,
    // shared data bus, driven by us only on write lines
    inout  wire [15:0]          SRAM_DQ,
    // chip enable, low for the whole line
    output reg                  SRAM_CE_N,
    // output enable, low for the whole of a read line
    output reg                  SRAM_OE_N,
    // write strobe, low during PULSE on write lines, the chip stores on its rising edge
    output wire                 SRAM_WE_N,
    // byte enables, always on (see below)
    output wire                 SRAM_UB_N,
    output wire                 SRAM_LB_N
);
    localparam LINE_BEATS = 8;      // 128-bit line / 16-bit SRAM word

    // every beat moves a full 16-bit word
    // happened above this bus (in the data cache), so both lanes are always enabled
    assign SRAM_UB_N = 1'b0;
    assign SRAM_LB_N = 1'b0;

    // write lines: SETUP -> PULSE -> HOLD per beat. read lines: S_READ per beat, then
    // S_LAST stores the final beat and acks
    localparam S_IDLE = 4'd0, S_SETUP = 4'd1, S_PULSE = 4'd2, S_HOLD = 4'd3, S_ACK = 4'd4,
               S_READ = 4'd5, S_LAST = 4'd6, S_WA = 4'd7, S_WB = 4'd8;
    reg [3:0]           state;
    // WE_N from the rising-edge FSM (WR_FAST = 0) or a falling-edge register (WR_FAST = 1):
    // low from half a cycle into S_WA until half a cycle into the beat's second cycle
    reg                 we_n_pos, we_n_neg;
    assign SRAM_WE_N = WR_FAST ? we_n_neg : we_n_pos;
    always @(negedge clk) we_n_neg <= rst || (state != S_WA);
    // line index of the transfer, addr[ADDR_BITS-1:4] SRAM_ADDR = {base, beat}
    reg [ADDR_BITS-5:0] base;
    // which 16-bit beat of the line is on the pins (0..7)
    reg [2:0]           beat;
    // cycles left in PULSE (write) or in the beat's address window (read)
    reg [7:0]           cnt;
    // copies of we and wdata latched at accept, so the master's bus can change afterwards
    reg                 we_r;
    reg [127:0]         wdata_r;
    // read: dq_in holds beat cap_beat this cycle
    reg                 cap;
    reg [2:0]           cap_beat;

    // DQ is driven only from registers, and only on write lines (dq_oe), so we never
    // drive the bus at the same time as the chip. dq_in samples the pins every cycle
    reg        dq_oe;
    reg [15:0] dq_out;
    reg [15:0] dq_in;
    assign SRAM_DQ = dq_oe ? dq_out : 16'bz;

    // power-up state: chip deselected, bus released
    initial begin
        state     = S_IDLE;
        ack       = 1'b0;
        rdata     = 128'h0;
        SRAM_CE_N = 1'b1;
        SRAM_OE_N = 1'b1;
        we_n_pos  = 1'b1;
        we_n_neg  = 1'b1;
        SRAM_ADDR = {(ADDR_BITS-1){1'b0}};
        dq_oe = 1'b0; dq_out = 16'h0; dq_in = 16'h0;
        base = 0; beat = 3'd0; cnt = 8'd0; we_r = 1'b0; wdata_r = 128'h0;
        cap = 1'b0; cap_beat = 3'd0;
    end

    always @(posedge clk) dq_in <= SRAM_DQ;

    // controller
    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            ack       <= 1'b0;
            cap       <= 1'b0;
            SRAM_CE_N <= 1'b1;
            SRAM_OE_N <= 1'b1;
            we_n_pos  <= 1'b1;
            dq_oe     <= 1'b0;
        end else begin
            ack <= 1'b0;
            // a read beat sampled on the last edge goes into its slot
            cap <= 1'b0;
            if (cap) rdata[16*cap_beat +: 16] <= dq_in;
            case (state)
            // wait for a request. !ack keeps a master that hasn't yet seen its ack from being
            // accepted again for a second, spurious transfer.
            // On accept: latch the line, put beat 0's address on the pins and drop CE_N. A read
            // also drops OE_N for the whole line, a write drives beat 0's data onto DQ
            S_IDLE: if (req && !ack) begin
                        base      <= addr[ADDR_BITS-1:4];
                        we_r      <= we;
                        wdata_r   <= wdata;
                        beat      <= 3'd0;
                        cnt       <= RD_CYCLES[7:0];
                        SRAM_ADDR <= {addr[ADDR_BITS-1:4], 3'd0};
                        SRAM_CE_N <= 1'b0;
                        // a read line keeps OE_N low throughout
                        SRAM_OE_N <= we;
                        dq_oe     <= we;
                        dq_out    <= wdata[15:0];
                        state     <= !we ? S_READ : WR_FAST ? S_WA : S_SETUP;
                    end
            // read: the beat's address has been out cnt cycles. On the edge that ends its
            // window dq_in samples it; the next beat's address goes out on that same edge
            S_READ: begin
                        cnt <= cnt - 8'd1;
                        if (cnt == 8'd1) begin
                            cap      <= 1'b1;
                            cap_beat <= beat;
                            if (beat == LINE_BEATS-1) begin
                                SRAM_CE_N <= 1'b1;
                                SRAM_OE_N <= 1'b1;
                                state     <= S_LAST;
                            end else begin
                                beat      <= beat + 3'd1;
                                SRAM_ADDR <= {base, beat + 3'd1};
                                cnt       <= RD_CYCLES[7:0];
                            end
                        end
                    end
            // the last beat goes into rdata on this edge (cap), so the line is whole with ack
            S_LAST: begin
                        ack   <= 1'b1;
                        state <= S_IDLE;
                    end
            // WR_FAST: first cycle of a beat, WE_N falls at its middle
            S_WA:   state <= S_WB;
            // WR_FAST: second cycle, WE_N rises at its middle; the next beat's address and
            // data (or the end of the line) follow on the edge after
            S_WB:   begin
                        if (beat == LINE_BEATS-1) begin
                            SRAM_CE_N <= 1'b1;
                            dq_oe     <= 1'b0;
                            ack       <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            beat      <= beat + 3'd1;
                            SRAM_ADDR <= {base, beat + 3'd1};
                            dq_out    <= wdata_r[16*(beat+1) +: 16];
                            state     <= S_WA;
                        end
                    end
            // address (and write data) have been on the pins for a full cycle. Load the PULSE
            // count and drop WE_N on the next edge
            S_SETUP: begin
                        cnt       <= WAIT_CYCLES[7:0];
                        we_n_pos  <= 1'b0;
                        state     <= S_PULSE;
                    end
            // wait WAIT_CYCLES cycles with WE_N low. On the last cycle WE_N goes back high
            // (the write commits on that rising edge) and we enter S_HOLD
            S_PULSE: begin
                        cnt <= cnt - 8'd1;
                        if (cnt == 8'd1) begin
                            // write ends; address and data held through HOLD
                            we_n_pos  <= 1'b1;
                            state     <= S_HOLD;
                        end
                    end
            // address and write data stay one more cycle after WE_N rose (hold time). Then
            // either set up the next beat's address and data and go back to S_SETUP, or after
            // beat 7 deselect the chip, release the bus and go to S_ACK
            S_HOLD:  begin
                        if (beat == LINE_BEATS-1) begin
                            SRAM_CE_N <= 1'b1;
                            dq_oe     <= 1'b0;
                            state     <= S_ACK;
                        end else begin
                            beat      <= beat + 3'd1;
                            SRAM_ADDR <= {base, beat + 3'd1};
                            dq_out    <= wdata_r[16*(beat+1) +: 16];
                            state     <= S_SETUP;
                        end
                    end
            // raise ack for one cycle, then back to S_IDLE ready for the next request
            S_ACK:   begin
                        ack   <= 1'b1;
                        state <= S_IDLE;
                    end
            endcase
        end
    end
endmodule
