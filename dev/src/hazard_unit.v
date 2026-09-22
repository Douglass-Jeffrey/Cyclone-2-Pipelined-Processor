`include "defines.vh"

// only time we need a stall/bubble in this design is when a consuming reg instr is behind a load.
// so if the pipeline is valid at id, ex stages and ex has a mem read, we need to allow current
// ex data to go to mem, but not allow id to go to ex since we want forwarding
module hazard_unit (
    // id fields
    input  wire       id_valid,
    input  wire [4:0] id_rs1_addr,
    input  wire [4:0] id_rs2_addr,
    input  wire       id_uses_rs1,
    input  wire       id_uses_rs2,
    input  wire       id_mem_write,

    //ex fields
    input  wire       ex_valid,
    input  wire       ex_mem_read,
    input  wire [4:0] ex_rd_addr,

    // if any branching, jump occurs, make a bubble 
    input  wire       redirect,

    // we also need to tell if stage to stall to prevent instructions from overwriting
    // id stage during the bubble
    output wire       if_stall,
    output wire       ex_bubble
);

    wire load_use = id_valid && ex_valid && ex_mem_read && (ex_rd_addr != 5'd0) &&
                    ((id_uses_rs1 && (id_rs1_addr == ex_rd_addr)) ||
                     (id_uses_rs2 && (id_rs2_addr == ex_rd_addr) && (!id_mem_write)));
                     //need !id_mem_write above to handle forwarding for mem->mem
                     // if we get rid of the clause we will have an extra cycle delay 
                     // when doing load rs1 a(rs2)->store rs2 b(rs1) one after another
                     // (where load's rs1 == store's rs2)

    assign if_stall  = load_use;

    // redirect or load use both demand a stall/bubble
    assign ex_bubble = load_use || redirect;
endmodule
