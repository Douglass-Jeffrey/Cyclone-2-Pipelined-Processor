// M4K RAM templates shared by the caches.  Written in the exact shapes
// Quartus documents for inference, so each one maps to M4K blocks.
// no_rw_check: the caches never depend on reading an entry in the same
// cycle it is written, so Quartus adds no bypass logic for that case.

// one write port, one read port; re low holds rdata
module sdp_ram #(
    parameter AW        = 9,
    parameter DW        = 32,
    parameter INIT_FILE = "",
    parameter [DW-1:0] INIT_VALUE = 0
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire          re,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);
    (* ramstyle = "M4K, no_rw_check" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = INIT_VALUE;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata <= mem[raddr];
    end
endmodule

// two read/write ports; port A has a clock enable, port B runs every cycle.
// Quartus 13 will not infer a true dual-port RAM with a clock enable, so
// synthesis instantiates altsyncram (port B on clock1, so it gets its own
// enable) and simulation uses the equivalent behavioural model.
module tdp_ram #(
    parameter AW = 12,
    parameter DW = 8
) (
    input  wire          clk,
    input  wire          en_a,
    input  wire          we_a,
    input  wire [AW-1:0] addr_a,
    input  wire [DW-1:0] wdata_a,
    output wire [DW-1:0] rdata_a,
    input  wire          we_b,
    input  wire [AW-1:0] addr_b,
    input  wire [DW-1:0] wdata_b,
    output wire [DW-1:0] rdata_b
);
`ifdef __ICARUS__
    reg [DW-1:0] mem [0:(1<<AW)-1];
    reg [DW-1:0] qa, qb;
    assign rdata_a = qa;
    assign rdata_b = qb;

    integer i;
    initial for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};

    always @(posedge clk) begin
        if (en_a) begin
            if (we_a) begin
                mem[addr_a] <= wdata_a;
                qa          <= wdata_a;
            end else begin
                qa          <= mem[addr_a];
            end
        end
    end

    always @(posedge clk) begin
        if (we_b) begin
            mem[addr_b] <= wdata_b;
            qb          <= wdata_b;
        end else begin
            qb          <= mem[addr_b];
        end
    end
`else
    altsyncram #(
        .operation_mode                     ("BIDIR_DUAL_PORT"),
        .intended_device_family             ("Cyclone II"),
        .ram_block_type                     ("M4K"),
        .lpm_type                           ("altsyncram"),
        .width_a                            (DW),
        .widthad_a                          (AW),
        .numwords_a                         (1 << AW),
        .width_b                            (DW),
        .widthad_b                          (AW),
        .numwords_b                         (1 << AW),
        .width_byteena_a                    (1),
        .width_byteena_b                    (1),
        .outdata_reg_a                      ("UNREGISTERED"),
        .outdata_reg_b                      ("UNREGISTERED"),
        .address_reg_b                      ("CLOCK1"),
        .indata_reg_b                       ("CLOCK1"),
        .wrcontrol_wraddress_reg_b          ("CLOCK1"),
        .clock_enable_input_a               ("NORMAL"),
        .clock_enable_input_b               ("NORMAL"),
        .clock_enable_output_a              ("BYPASS"),
        .clock_enable_output_b              ("BYPASS"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .power_up_uninitialized             ("FALSE")
    ) u_ram (
        .clock0    (clk),
        .clocken0  (en_a),
        .wren_a    (we_a),
        .address_a (addr_a),
        .data_a    (wdata_a),
        .q_a       (rdata_a),
        .clock1    (clk),
        .clocken1  (1'b1),
        .wren_b    (we_b),
        .address_b (addr_b),
        .data_b    (wdata_b),
        .q_b       (rdata_b)
    );
`endif
endmodule
