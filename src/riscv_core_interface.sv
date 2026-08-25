/**
 * riscv_core_interface.sv
 *
 * RISC-V 32-bit Processor
 *
 * ECE 18-447
 * Carnegie Mellon University
 *
 * This is the file that we (expect) you to use to wire up
 * your core to the I/D caches, as well as to memory.
 *
 * At this point in the semester, we know the core pipeline is but a small part of a CPU.
 * This file is where you can stick whatever additional components (victim caches, etc...)
 * that are part of the CPU's memory hierarchy but that you do not wish to put in riscv_core.sv directly.
 *
 * This is where you can start to add code and make modifications to fully
 * implement the processor. You can add any additional files or change and
 * delete files as you need to implement the processor, provided that they are
 * under the src directory. You may not change any files outside the src
 * directory. The only requirement is that there is a riscv_core module with the
 * interface defined below, with the same port names as below.
 *
 * The Makefile will automatically find any files you add, provided they are
 * under the src directory and have either a *.v, *.vh, or *.sv extension. The
 * files may be nested in subdirectories under the src directory as well.
 * Additionally, the build system sets up the include paths so that you can
 * place header files (*.vh) in any subdirectory in the src directory, and
 * include them from anywhere else inside the src directory.
 *
 * The compiler and synthesis tools support both Verilog and System Verilog
 * constructs and syntax, so you can write either Verilog or System Verilog
 * code, or mix both as you please.
 **/

/*----------------------------------------------------------------------------*
 *  You may edit this file and add or change any files in the src directory.  *
 *----------------------------------------------------------------------------*/

// RISC-V Includes
`include "riscv_abi.vh"             // ABI registers and definitions
`include "riscv_isa.vh"             // RISC-V ISA definitions
`include "memory_segments.vh"       // Memory segment starting addresses

// Local Includes
`include "internal_defines.vh"      // Control signals struct, ALU ops
`include "parameters.vh"            // Cache parameters for sweeping

// Force the compiler to throw an error if any variables are undeclared
`default_nettype none

/**
 * Wrapper around the core of the RISC-V processor, and the private caches for that core.
 * everything except main memory.
 *
 * Inputs:
 *  - clk                   The global clock for the processor.
 *  - rst_l                 The asynchronous, active low reset for the processor.
 *  - mem_excpt             Indicates that an invalid instruction address was given
 *                          to memory.
 *  - mem_data_load         The data loaded from the mem_data_load_addr address in memory.
 *  - mem_data_load_addr    The address of the data that is being returned on mem_data_load
 *  - mem_data_load_valid   Indicates that the mem_data_load is valid data from memory
 *                          (As opposed to not having initiated a load 8 cycles ago)
 *
 * Outputs:
 *  - mem_data_load_en      Indicates that data from the mem_data_addr address in
 *                          memory should be loaded.
 *  - halted                Indicates that the processor has stopped because of a
 *                          syscall or exception. Used to indicate to the testbench
 *                          to end simulation. Must be held until next clock cycle.
 *  - mem_data_store_mask   Byte-enable bit mask  signal indicating which bytes of data_store
 *                          should be written to the data_addr address in memory.
 *  - mem_data_addr         The address of the data to load or store from memory.
 *  - mem_data_stall        stall data load from memory if multicycle.
 *  - mem_data_store        The data to store to the mem_data_addr address in memory.
 **/
module riscv_core_interface (
     input  logic                 clk, rst_l, 
     input  logic                 mem_excpt,
     input  logic [3:0] [31:0]    mem_data_load,
     input  logic [29:0]          mem_data_load_addr,
     input  logic                 mem_data_load_valid,

     output logic                 mem_data_load_en, 
     output logic                 halted,
     output logic [3:0]           mem_data_store_mask,
     output logic [29:0]          mem_data_addr,
     output logic                 mem_data_stall,
     output logic [31:0]          mem_data_store
);

    //core to cache
    logic core_data_load_en, core_read_instr;
    logic [31:0] core_data_store;
    logic [29:0] core_instr_addr, core_data_addr;
    logic [3:0] core_data_store_mask;
    //stall icache while pipeline (EX, MEM..) is still stalled by dcache miss
    logic core_stall_icache; 
    logic core_cancel_instr; //cancel an in-flight instr on a mispredict

    //cache to core
    logic [29:0] core_rsp_icache_addr;
    logic [31:0] core_rsp_dcache_data, core_rsp_icache_data;
    logic [31:0] read_data;
    logic core_rsp_dcache_ready, core_rsp_icache_ready;
    logic core_data_mem_excpt, core_instr_mem_excpt;

    //dcache to memory
    logic dcache_mem_req_data_load_en;
    logic [3:0] dcache_mem_req_store_mask;
    logic [29:0] dcache_mem_req_addr;
    logic [31:0] dcache_mem_req_store_data;

    //icache to memory
    logic icache_mem_req_data_load_en;
    logic [29:0] icache_mem_req_addr;
    //asserted when dcache / icache makes a request to memory
    //used to indicate if the memory is 'free' for the dcache / icache
    logic dcache_req, icache_req;

    //perf counters
    logic dcache_eviction, icache_eviction;
    logic dcache_read_hit, icache_read_hit;
    logic dcache_read_miss, icache_read_miss;

    assign mem_data_stall = 1'b0; //hardcoded to 0

    /***** CORE TO CACHE *****/

    /***** CACHE TO MEMORY ARBITRATION *****/
    //memory can only take a load OR store request every cycle, not both
    always_comb begin
        //prioritize dcache read / write from memory (default)
        //mem_data_addr will be overwritten by icache addr if needed
        mem_data_store_mask = dcache_mem_req_store_mask;
        mem_data_addr = dcache_mem_req_addr;
        mem_data_store = dcache_mem_req_store_data;
        if (dcache_mem_req_data_load_en) begin
            //dcache read
            mem_data_load_en = 1'b1;
            dcache_req = 1'b1; //dcache request
            icache_req = 1'b0;
        end
        else if (dcache_mem_req_store_mask != 4'b0000) begin
            //dcache write (already indicated in store_mask)
            mem_data_load_en = 1'b0;
            dcache_req = 1'b1; //dcache request
            icache_req = 1'b0;
        end else begin
            //dcache made no memory requests, check icache read from memory
            if (icache_mem_req_data_load_en) begin
                mem_data_load_en = 1'b1;
                mem_data_addr = icache_mem_req_addr; //use icache addr
                dcache_req = 1'b0;
                icache_req = 1'b1; //icache request
            end else begin
                //icache does not write to memory
                //dcache and icache made no memory requests
                mem_data_load_en = 1'b0;
                dcache_req = 1'b0;
                icache_req = 1'b0;
            end
        end
    end

    
    /***** MEMORY TO CACHE LOGIC *****/
    //no need for arbitration, send the returned memory data to both caches
    //cache controllers will dispose of the data if not required
    

    /***** CACHE TO CORE LOGIC *****/



    // TODO: We recommend 18-447 students instantiate riscv_core here
    riscv_core core_inst (.clk, .rst_l, .halted,
                .instr_mem_excpt(core_instr_mem_excpt), 
                .data_mem_excpt(core_data_mem_excpt), 
                .dcache_ready(core_rsp_dcache_ready),
                .icache_ready(core_rsp_icache_ready),
                .in_instr_addr(core_rsp_icache_addr),
                .instr(core_rsp_icache_data), //icache data is the instr
                .dcache_read_hit(dcache_read_hit),
                .data_load_fwd(read_data), //data to forward from MEM2 to ID
                .data_load(core_rsp_dcache_data), //dcache data is data_load
                .data_load_en(core_data_load_en), 
                .data_store_mask(core_data_store_mask), 
                .out_instr_addr(core_instr_addr), 
                .data_addr(core_data_addr), 
                .stall_icache(core_stall_icache),
                .cancel_instr(core_cancel_instr),
                .read_instr(core_read_instr),
                .data_store(core_data_store));

    //dcache controller
    cache_controller_new  #(.INDEX_BITS(DATA_CACHE_INDEX_BITS),
                        .BLOCK_OFFSET_BITS(DATA_BLOCK_OFFSET_BITS),
                        .WAYS(DATA_CACHE_WAYS),
                        .POLICY(DATA_CACHE_POLICY)) d_cache 
                        (.clk, .rst_l,
                        //Core to cache (input)
                        .core_req_we(core_data_store_mask > 4'd0), 
                        .core_req_re(core_data_load_en),
                        .core_req_addr(core_data_addr), //load data addr
                        .core_req_store_mask(core_data_store_mask),
                        .core_req_store_data(core_data_store),
                        .core_req_cancel(),
                        .core_req_stall_mem(),
                        //Cache to core (output)
                        .core_rsp_addr(),
                        .read_data(read_data),
                        .core_rsp_data(core_rsp_dcache_data),
                        .core_rsp_data_valid(),
                        .core_rsp_ready(core_rsp_dcache_ready),
                        .core_rsp_excpt(core_data_mem_excpt),
                        //Memory to cache (input)
                        .mem_rsp_data(mem_data_load),
                        .mem_rsp_valid(mem_data_load_valid),
                        .mem_rsp_addr(mem_data_load_addr),
                        .mem_rsp_ready(dcache_req), //priority given to dcache
                        .mem_rsp_excpt(mem_excpt),
                        //Cache to memory (output)
                        .mem_req_data_load_en(dcache_mem_req_data_load_en),
                        .mem_req_store_mask(dcache_mem_req_store_mask),
                        .mem_req_addr(dcache_mem_req_addr),
                        .mem_req_store_data(dcache_mem_req_store_data),
                        //Data collection (output)
                        .is_eviction(dcache_eviction),
                        .read_hit(dcache_read_hit),
                        .read_miss(dcache_read_miss));

    //icache controller
    cache_controller_new  #(.INDEX_BITS(INSTR_CACHE_INDEX_BITS),
                        .BLOCK_OFFSET_BITS(INSTR_BLOCK_OFFSET_BITS),
                        .WAYS(INSTR_CACHE_WAYS),
                        .POLICY(INSTR_CACHE_POLICY)) i_cache
                    (.clk, .rst_l,
                    //Core to cache (input)
                    .core_req_we(1'b0), //never write to icache
                    .core_req_re(core_read_instr), //make instr read request
                    .core_req_addr(core_instr_addr), //load instr addr
                    .core_req_store_mask(4'b0000), //not storing instrs
                    .core_req_store_data(32'd0), //not storing instrs
                    .core_req_cancel(core_cancel_instr), //cancel invalid instr
                    .core_req_stall_mem(core_stall_icache), //stall icache
                    //Cache to core (output)
                    .core_rsp_addr(core_rsp_icache_addr),
                    .read_data(),
                    .core_rsp_data(core_rsp_icache_data),
                    .core_rsp_data_valid(),
                    .core_rsp_ready(core_rsp_icache_ready),
                    .core_rsp_excpt(core_instr_mem_excpt),
                    //Memory to cache (input)
                    .mem_rsp_data(mem_data_load),
                    .mem_rsp_valid(mem_data_load_valid),
                    .mem_rsp_addr(mem_data_load_addr),
                    .mem_rsp_ready(icache_req), //priority given to icache
                    .mem_rsp_excpt(mem_excpt),
                    //Cache to memory (output)
                    .mem_req_data_load_en(icache_mem_req_data_load_en),
                    .mem_req_store_mask(), //not storing instrs
                    .mem_req_addr(icache_mem_req_addr),
                    .mem_req_store_data(), //not storing instrs
                    //Data collection (output)
                    .is_eviction(icache_eviction),
                    .read_hit(icache_read_hit),
                    .read_miss(icache_read_miss));

endmodule: riscv_core_interface
