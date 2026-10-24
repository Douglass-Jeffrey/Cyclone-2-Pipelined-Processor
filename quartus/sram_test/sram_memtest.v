//============================================================================
// sram_memtest -- exercises the whole SRAM through sram_ctl, forever:
//   phase 0  write every line          phase 1  read it all back, compare
//   phase 2  write every bit inverted  phase 3  read it all back, compare
//
// Each 16-bit word's data is built from its own address, so an address line
// that is stuck or shorted (two addresses landing in one cell) reads back
// another address's data.  The inverted round puts both 0 and 1 on every bit
// of every cell, so a stuck data bit shows up too; and because consecutive
// writes to a cell always differ, a write that silently fails cannot pass by
// leaving the right data behind.
//============================================================================
module sram_memtest #(
    parameter ADDR_BITS   = 19,     // bytes behind sram_ctl (19: the DE1's 512 KB)
    parameter WAIT_CYCLES = 2
) (
    input  wire        clk,
    input  wire        rst,

    output reg  [31:0] rounds,          // completed rounds (all four phases)
    output reg  [31:0] errors,          // 16-bit words that read back wrong, all rounds
    output reg  [31:0] first_addr,      // byte address of the first wrong word
    output reg  [15:0] first_expected,
    output reg  [15:0] first_got,
    output wire [1:0]  phase,

    // physical SRAM pins, straight through to sram_ctl
    output wire [ADDR_BITS-2:0] SRAM_ADDR,
    inout  wire [15:0]          SRAM_DQ,
    output wire                 SRAM_CE_N,
    output wire                 SRAM_OE_N,
    output wire                 SRAM_WE_N,
    output wire                 SRAM_UB_N,
    output wire                 SRAM_LB_N
);
    localparam LBITS = ADDR_BITS - 4;           // line index bits

    reg  [1:0]       ph;
    reg  [LBITS-1:0] line;
    wire             inverted = ph[1];
    wire             writing  = !ph[0];
    wire             ack;
    wire [127:0]     rdata;
    assign phase = ph;

    // the word stored at SRAM word address {l, b}
    function [15:0] pattern(input [LBITS-1:0] l, input [2:0] b, input inv);
        reg [17:0] w;
        begin
            w = {l, b};
            pattern = (w[15:0] ^ {w[17:16], 14'b0}) ^ {16{inv}};
        end
    endfunction

    // simulation must count an X read-back as wrong; synthesis has no X
    function differs(input [15:0] a, input [15:0] b);
`ifdef __ICARUS__
        differs = (a !== b);
`else
        differs = (a != b);
`endif
    endfunction

    reg [127:0] expect_line;
    reg [3:0]   nbad;               // wrong words in the line just read
    reg [2:0]   fbeat;              // lowest wrong beat
    integer     b;
    always @(*) begin
        nbad  = 4'd0;
        fbeat = 3'd0;
        for (b = 7; b >= 0; b = b - 1) begin
            expect_line[16*b +: 16] = pattern(line, b[2:0], inverted);
            if (differs(rdata[16*b +: 16], expect_line[16*b +: 16])) begin
                nbad  = nbad + 4'd1;
                fbeat = b[2:0];
            end
        end
    end

    // req stays high: sram_ctl takes the next line the cycle after each ack
    always @(posedge clk) begin
        if (rst) begin
            ph <= 2'd0; line <= {LBITS{1'b0}};
            rounds <= 32'd0; errors <= 32'd0;
            first_addr <= 32'd0; first_expected <= 16'd0; first_got <= 16'd0;
        end else if (ack) begin
            if (!writing && nbad != 4'd0) begin
                errors <= errors + nbad;
                if (errors == 32'd0) begin
                    first_addr     <= {line, fbeat, 1'b0};
                    first_expected <= expect_line[16*fbeat +: 16];
                    first_got      <= rdata[16*fbeat +: 16];
                end
            end
            if (line == {LBITS{1'b1}}) begin
                ph <= ph + 2'd1;
                if (ph == 2'd3) rounds <= rounds + 32'd1;
            end
            line <= line + 1'b1;
        end
    end

    sram_ctl #(
        .ADDR_BITS   (ADDR_BITS),
        .WAIT_CYCLES (WAIT_CYCLES)
    ) u_ctl (
        .clk       (clk),
        .rst       (rst),
        .req       (!rst),
        .we        (writing),
        .addr      ({{(32-ADDR_BITS){1'b0}}, line, 4'b0}),
        .wdata     (expect_line),
        .rdata     (rdata),
        .ack       (ack),
        .SRAM_ADDR (SRAM_ADDR),
        .SRAM_DQ   (SRAM_DQ),
        .SRAM_CE_N (SRAM_CE_N),
        .SRAM_OE_N (SRAM_OE_N),
        .SRAM_WE_N (SRAM_WE_N),
        .SRAM_UB_N (SRAM_UB_N),
        .SRAM_LB_N (SRAM_LB_N)
    );
endmodule
