// synchronous instruction memory
`include "defines.vh"

module imem #(
    parameter DEPTH_WORDS = 256,
    parameter INIT_FILE   = "program.hex"
)(
    input  wire        clk,
    input  wire [31:0] addr,    // byte address (PC); addr[1:0] assumed 0
    output wire [31:0] instr
);
    localparam AW = $clog2(DEPTH_WORDS);

    reg [31:0] mem [0:DEPTH_WORDS-1];
    reg [31:0] addr_reg; 

    integer i;
    initial begin
        // words past the end of the program read as 0 (a NOP) rather than X
        for (i = 0; i < DEPTH_WORDS; i = i + 1) mem[i] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        addr_reg <= addr;
    end

    assign instr = mem[addr_reg[AW+1:2]];
endmodule
