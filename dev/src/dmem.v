// data memory + load/store alignment
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

    // One byte-wide memory per byte lane, each with its own write enable.
    (* ramstyle = "M4K" *) reg [7:0] mem0 [0:DEPTH_WORDS-1];   // bits  7:0
    (* ramstyle = "M4K" *) reg [7:0] mem1 [0:DEPTH_WORDS-1];   // bits 15:8
    (* ramstyle = "M4K" *) reg [7:0] mem2 [0:DEPTH_WORDS-1];   // bits 23:16
    (* ramstyle = "M4K" *) reg [7:0] mem3 [0:DEPTH_WORDS-1];   // bits 31:24

    reg [31:0] addr_reg;
    reg [2:0]  funct3_reg;
    reg        mem_read_reg;

    // INIT_FILE holds 32-bit words split them across the four lanes
    reg [31:0] init_words [0:DEPTH_WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < DEPTH_WORDS; k = k + 1) init_words[k] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, init_words);
        for (k = 0; k < DEPTH_WORDS; k = k + 1) begin
            mem0[k] = init_words[k][7:0];
            mem1[k] = init_words[k][15:8];
            mem2[k] = init_words[k][23:16];
            mem3[k] = init_words[k][31:24];
        end
    end

    always @(posedge clk) begin
        addr_reg     <= addr;
        funct3_reg   <= funct3;
        mem_read_reg <= valid && mem_read;
    end

    // Read port. The RAM's own output register supplies the one-cycle
    // latency, so the index here is the LIVE address, not addr_reg.
    wire [AW-1:0] widx   = addr[AW+1:2];
    wire [1:0]    boff_r = addr_reg[1:0];
    reg  [31:0]   word_r;
    always @(posedge clk) word_r <= {mem3[widx], mem2[widx], mem1[widx], mem0[widx]};

    // load
    always @(*) begin
        if (!mem_read_reg) begin
            rdata = 32'd0;
        end else begin
            case (funct3_reg)
                3'b000: rdata = {{24{word_r[8*boff_r+7]}},      word_r[8*boff_r     +: 8]};  // LB
                3'b001: rdata = {{16{word_r[16*boff_r[1]+15]}}, word_r[16*boff_r[1] +: 16]}; // LH
                3'b010: rdata = word_r;                                                      // LW
                3'b100: rdata = {24'b0,                     word_r[8*boff_r     +: 8]};      // LBU
                3'b101: rdata = {16'b0,                     word_r[16*boff_r[1] +: 16]};     // LHU
                default: rdata = word_r;
            endcase
        end
    end


    // synchronous write, widx shared with read
    wire [1:0]    boff_w = addr[1:0];

    //store
    reg [31:0] st_wdata;
    reg [3:0]  st_be;
    always @(*) begin
        case (funct3)
            3'b000: begin st_wdata = {4{wdata[7:0]}};  st_be = 4'b0001 << boff_w; end // SB
            3'b001: begin st_wdata = {2{wdata[15:0]}}; st_be = 4'b0011 << boff_w; end // SH
            3'b010: begin st_wdata = wdata;            st_be = 4'b1111;         end   // SW
            default:begin st_wdata = wdata;            st_be = 4'b0000;         end
        endcase
    end

    // one write port per lane; edge case of read during write to the same
    // address cannot matter here, a STORE has mem_read = 0
    wire we = valid && mem_write;
    always @(posedge clk) if (we && st_be[0]) mem0[widx] <= st_wdata[7:0];
    always @(posedge clk) if (we && st_be[1]) mem1[widx] <= st_wdata[15:8];
    always @(posedge clk) if (we && st_be[2]) mem2[widx] <= st_wdata[23:16];
    always @(posedge clk) if (we && st_be[3]) mem3[widx] <= st_wdata[31:24];
endmodule
