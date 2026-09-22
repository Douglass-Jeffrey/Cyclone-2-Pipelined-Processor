//data memory + load/store alignment

`include "defines.vh"

module dmem #(
    parameter DEPTH_WORDS = 256,
    parameter INIT_FILE   = ""
)(
    input  wire        clk,
    input  wire        valid,
    input  wire [31:0] addr,       // byte address (ALU result)
    input  wire [2:0]  funct3,     // instr[14:12]
    input  wire        mem_read,
    input  wire        mem_write,
    input  wire [31:0] wdata,      // raw rs2_data
    output reg  [31:0] rdata       // sign/zero-extended load result
);
    localparam AW = $clog2(DEPTH_WORDS);

    reg [31:0] mem [0:DEPTH_WORDS-1];

    reg [31:0] addr_reg;
    reg [2:0]  funct3_reg;
    reg        mem_read_reg;

    integer k;
    initial begin
        for (k = 0; k < DEPTH_WORDS; k = k + 1) mem[k] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        addr_reg     <= addr;
        funct3_reg   <= funct3;
        mem_read_reg <= valid && mem_read;
    end

    wire [AW-1:0] widx_r = addr_reg[AW+1:2];
    wire [1:0]    boff_r = addr_reg[1:0];
    wire [31:0]   word_r = mem[widx_r];

    // load
    always @(*) begin
        if (!mem_read_reg) begin
            rdata = 32'd0;
        end else begin
            case (funct3_reg)
                3'b000: rdata = {{24{word_r[8*boff_r+7]}},      word_r[8*boff_r     +: 8]};  // LB
                3'b001: rdata = {{16{word_r[16*boff_r[1]+15]}}, word_r[16*boff_r[1] +: 16]}; // LH
                3'b010: rdata = word_r;                                               // LW
                3'b100: rdata = {24'b0,                     word_r[8*boff_r     +: 8]};  // LBU
                3'b101: rdata = {16'b0,                     word_r[16*boff_r[1] +: 16]}; // LHU
                default: rdata = word_r;
            endcase
        end
    end


    // synchronous write
    wire [AW-1:0] widx_w = addr[AW+1:2];
    wire [1:0]    boff_w = addr[1:0];

    //store
    reg [31:0] st_wdata;
    reg [3:0]  st_be;
    always @(*) begin
        case (funct3)
            3'b000: begin st_wdata = {4{wdata[7:0]}};  st_be = 4'b0001 << boff_w; end // SB
            3'b001: begin st_wdata = {2{wdata[15:0]}}; st_be = 4'b0011 << boff_w; end // SH
            3'b010: begin st_wdata = wdata;            st_be = 4'b1111;         end // SW
            default:begin st_wdata = wdata;            st_be = 4'b0000;         end
        endcase
    end

    integer i;
    always @(posedge clk) begin
        if (valid && mem_write)
            for (i = 0; i < 4; i = i + 1)
                if (st_be[i]) mem[widx_w][8*i +: 8] <= st_wdata[8*i +: 8];
    end
endmodule