// synchronous instruction memory
`include "defines.vh"

module imem #(
    parameter DEPTH_WORDS = 256,
    parameter INIT_FILE   = "program.hex"
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire [31:0] addr,    // byte address (PC), addr[1:0] assumed 0
    output reg  [31:0] instr
);
    localparam AW = $clog2(DEPTH_WORDS);

    (* ramstyle = "M4K", romstyle = "M4K" *) reg [31:0] mem [0:DEPTH_WORDS-1];

    integer i;
    initial begin
        // words past the end of the program read as 0 (a NOP) rather than X
        for (i = 0; i < DEPTH_WORDS; i = i + 1) mem[i] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    // read on the clock edge (the M4K ROM template): the block's own address
    // register gives the one-cycle latency, and clk_en low holds instr
    always @(posedge clk) begin
        if (clk_en) begin
            instr <= mem[addr[AW+1:2]];
        end
    end
endmodule
