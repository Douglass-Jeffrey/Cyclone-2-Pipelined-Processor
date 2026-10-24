// Shares sram_ctl between the two caches, one line transfer at a time.
// The data cache wins when ther is a tie, since dcache miss freezes the whole pipeline, while an
// instruction miss only holds the front end.
module mem_arbiter #(
    parameter AW = 19                   // SRAM byte-address bits
) (
    input  wire          clk,
    input  wire          rst,
    // data cache
    input  wire          d_req,
    input  wire          d_we,
    input  wire [AW-1:0] d_addr,
    input  wire [127:0]  d_wdata,
    output wire          d_ack,
    // instruction cache (reads only)
    input  wire          i_req,
    input  wire [AW-1:0] i_addr,
    output wire          i_ack,
    // sram_ctl; its rdata goes straight to both caches
    output wire          req,
    output wire          we,
    output wire [31:0]   addr,
    output wire [127:0]  wdata,
    input  wire          ack
);
    reg busy, own_d;

    wire pick_d = busy ? own_d : d_req;
    assign req   = busy ? (own_d ? d_req : i_req) : (d_req || i_req);
    assign we    = pick_d && d_we;
    assign addr  = {{(32-AW){1'b0}}, pick_d ? d_addr : i_addr};
    assign wdata = d_wdata;
    assign d_ack = ack &&  own_d;
    assign i_ack = ack && !own_d;

    // sram_ctl accepts on the same edge as the grant (req && !ack)
    always @(posedge clk) begin
        if (rst) begin
            busy  <= 1'b0;
            own_d <= 1'b0;
        end else if (!busy) begin
            if (req && !ack) begin
                busy  <= 1'b1;
                own_d <= d_req;
            end
        end else if (ack) begin
            busy <= 1'b0;
        end
    end
endmodule
