/**
 * riscv_core_timing.sv
 *
 * RISC-V 32-bit Processor
 *
 * ECE 18-447
 * Carnegie Mellon University
 *
 * This file contains the top module used when the processor is synthesized.
 *
 * This top module is "riscv_core_timing" and is intended only for synthesis. It
 * should not be used for simulation, as it is not behaviorally accurate. It
 * acts as a synthesis wrapper and is responsible for providing a realistic
 * model for memory's combinational delay.
 *
 * The top module simply hooks up the fake memory timing model to the processor
 * core, providing a (semi-realistic) delay for memory.
 *
 * Authors:
 *  - 2017: James Hoe
 *  - 2017: Brandon Perez
 **/

/*----------------------------------------------------------------------------*
 *                          DO NOT MODIFY THIS FILE!                          *
 *          You should only add or change files in the src directory!         *
 *----------------------------------------------------------------------------*/

// These modules are only included when we are running synthesis
`ifndef SIMULATION_18447

// Force the compiler to throw an error if any variables are undeclared
`default_nettype none

// RISC-V Includes
`include "riscv_isa.vh"             // Definition of XLEN parameters
`include "riscv_uarch.vh"           // Definition of delay and other parameters

/*----------------------------------------------------------------------------
 * Synthesis Top Module
 *----------------------------------------------------------------------------*/

/**
 * The top module for the RISC-V core used for synthesis.
 *
 * For synthesis, a synthesizable, but non-behaviorally accurate model is used
 * memory. This memory model creates a delay for the combinational reads from
 * memory, so that the reported timing remains realistic.
 *
 * Inputs:
 *  - clk               The global clock for the processor.
 *  - rst_l             The asynchronous, active low reset for the processor.
 *  - instr_mem_excpt   Indicates that an invalid instruction address was given
 *                      to memory.
 *  - data_mem_excpt    Indicates that an invalid address was given to the data
 *                      memory during a load and/or store operation.
 *  - instr             The instruction loaded loaded from the instr_addr
 *                      address in memory.
 *  - data_load         The data loaded from the data_addr address in memory.
 *
 * Outputs:
 *  - data_load_en      Indicates that data from the data_addr address in
 *                      memory should be loaded.
 *  - halted            Indicates that the processor has stopped because of a
 *                      syscall or exception. Used to indicate to the testbench
 *                      to end simulation. Must be held until next clock cycle.
 *  - data_store_mask   Byte-enable bit mask signal indicating which bytes of data_store
 *                      should be written to the data_addr address in memory.
 *  - instr_addr        The address of the instruction to load from memory.
 *  - instr_stall       stall instruction load from memory if multicycle.
 *  - data_addr         The address of the data to load or store from memory.
 *  - data_stall        stall data load from memory if multicycle.
 *  - data_store        The data to store to the data_addr address in memory.
 **/
/* module riscv_core_timing
    // Import the width of signals and the memory read width
    import RISCV_ISA::XLEN, RISCV_ISA::XLEN_BYTES;
    import RISCV_UArch::MEMORY_ADDR_WIDTH, RISCV_UArch::MEMORY_READ_WIDTH, RISCV_UArch::IMEMORY_READ_DELAY, RISCV_UArch::DMEMORY_READ_DELAY;

    (input  logic                                   clk, rst_l, instr_mem_excpt,
     input  logic                                   data_mem_excpt,
     output logic                                   data_load_en, halted,
     output logic [XLEN_BYTES-1:0]                  data_store_mask,
     output logic [MEMORY_ADDR_WIDTH-1:0]           instr_addr, data_addr,
     output logic                                   instr_stall, data_stall,
     output logic [XLEN-1:0]                        data_store,
     output logic [MEMORY_READ_WIDTH-1:0][XLEN-1:0] data_load,
     output logic [MEMORY_READ_WIDTH-1:0][XLEN-1:0] instr);

    // Import the parameter used to control memory's combinational delay
    import RISCV_UArch::MEMORY_DELAY_WIDTH;

    // Signal to encapsulate the load/store enable signals for data memory
    logic dmem_data_en;

    // The RISC-V core
    riscv_core RISCV_Core(.clk, .rst_l, .instr_mem_excpt, .data_mem_excpt,
            .instr, .data_load,
            .data_load_en, .halted, .data_store_mask, .instr_addr, .instr_stall, .data_addr, .data_stall,
            .data_store);

            riscv_core RISCV_Core (
                .clk            (clk),
                .rst_l          (rst_l),
                .mem_load_data  (mem_load_data),
                .mem_req_addr   (mem_req_addr),
                .mem_resp_valid (mem_resp_valid),
                .mem_excpt      (mem_excpt),
                .load_en        (mem_load_en),
                .halted         (halted),
                .mem_store_mask (mem_store_mask),
                .mem_store_data (mem_store_data),
                .mem_resp_addr  (mem_resp_addr),
                .mem_stall      (mem_stall)
            );
    Model for the delay through the data memory port of the main memory for
     * the processor. 
    assign dmem_data_en = ^({data_store_mask, data_load_en});
    fake_memory_delay #(.LOAD_WORDS(MEMORY_READ_WIDTH), .WORD_WIDTH(XLEN),
                        .ADDR_WIDTH(MEMORY_ADDR_WIDTH), .DELAY_WIDTH(MEMORY_DELAY_WIDTH),
                        .PIPELINED(DMEMORY_READ_DELAY))
    Fake_DMem_Delay(.clk, .addr(data_addr), .stall(data_stall), .en(dmem_data_en),
                    .data(data_load));

endmodule: riscv_core_timing
*/

module riscv_core_timing
    // Import the width of signals and the memory read width
    import RISCV_ISA::XLEN, RISCV_ISA::XLEN_BYTES;
    import RISCV_UArch::MEMORY_ADDR_WIDTH, RISCV_UArch::MEMORY_READ_WIDTH, RISCV_UArch::IMEMORY_READ_DELAY, RISCV_UArch::DMEMORY_READ_DELAY;

    (input  logic                                   clk, rst_l, instr_mem_excpt,
     input  logic                                   data_mem_excpt,
     output logic                                   data_load_en, halted,
     output logic [XLEN_BYTES-1:0]                  data_store_mask,
     output logic [MEMORY_ADDR_WIDTH-1:0]           instr_addr, data_addr,
     output logic                                   instr_stall, data_stall,
     output logic [XLEN-1:0]                        data_store,
     output logic [MEMORY_READ_WIDTH-1:0][XLEN-1:0] data_load,
     output logic [MEMORY_READ_WIDTH-1:0][XLEN-1:0] instr);

    // Import the parameter used to control memory's combinational delay
    import RISCV_UArch::MEMORY_DELAY_WIDTH;

    // Signal to encapsulate the load/store enable signals for data memory
    logic dmem_data_en;

    /*
    // The RISC-V core
    riscv_core RISCV_Core(.clk, .rst_l, .instr_mem_excpt, .data_mem_excpt,
            .instr, .data_load,
            .data_load_en, .halted, .data_store_mask, .instr_addr, .instr_stall, .data_addr, .data_stall,
            .data_store);
    */

    riscv_core_interface RISCV_Core (
        .clk            (clk),
        .rst_l          (rst_l),
        .mem_excpt          (data_mem_excpt),
        .mem_data_load      (data_load),
        .mem_data_load_en            (data_load_en),
        .halted             (halted),
        .mem_data_store_mask     (data_store_mask),
        .mem_data_stall          (data_stall),
        .mem_data_store     (data_store),
        .mem_data_addr       (data_addr),
        .mem_data_load_valid     (1'b1)
    );

    /* Model for the delay through the data memory port of the main memory for
     * the processor. */
    assign dmem_data_en = ^({data_store_mask, data_load_en});
    fake_memory_delay #(.LOAD_WORDS(MEMORY_READ_WIDTH), .WORD_WIDTH(XLEN),
                        .ADDR_WIDTH(MEMORY_ADDR_WIDTH), .DELAY_WIDTH(MEMORY_DELAY_WIDTH),
                        .PIPELINED(DMEMORY_READ_DELAY))
    Fake_DMem_Delay(.clk, .addr(data_addr), .stall(data_stall), .en(dmem_data_en),
                    .data(data_load));

endmodule: riscv_core_timing


/*----------------------------------------------------------------------------
 * Model for Combinational Memory Delay
 *----------------------------------------------------------------------------*/

/**
 * A synthesizable, but behaviorally inaccurate model for main memory.
 *
 * This gives the combinational reads for memory a delay, so that the
 * synthesized designs have realistic timing on their critical path.
 *
 * Parameters:
 *  - DELAY_WIDTH   An ad-hoc parameter to control the combinational delay
 *                  between the input and output. The delay is directly
 *                  proportional to this parameter. This parameter must be
 *                  between 2 and ADDR_WIDTH/2.
 *
 * Inputs:
 *  - clk           The global clock for the design.
 *  - addr          The address of the data to interact with in memory.
 *  - stall         read stall signal (if multicycle)
 * Outputs:
 *  - data          The data loaded from the addr address in memory.
 **/
module fake_memory_delay
    #(parameter LOAD_WORDS=0, WORD_WIDTH=0, ADDR_WIDTH=0, DELAY_WIDTH=0, PIPELINED=0)
    (input  logic                                   clk, en,
     input  logic [ADDR_WIDTH-1:0]                  addr,
     input  logic                                   stall,
     output logic [LOAD_WORDS-1:0][WORD_WIDTH-1:0]  data);

    // Variables for generating combinational delay
    logic                   carry0, carry1, carry2, carry3;
    logic [DELAY_WIDTH-1:0]  input_sample, mem;
    logic [2*DELAY_WIDTH-1:0] prod;   // note double-length prod

    logic [LOAD_WORDS-1:0][WORD_WIDTH-1:0]  data_comb, data_ff;

    // Create a long combinational circuit to generate delay
    assign input_sample = {addr[ADDR_WIDTH-1:ADDR_WIDTH-DELAY_WIDTH+1], en};
    assign prod         = (input_sample ^ addr[DELAY_WIDTH-1:0]) * mem;

    // Sample various values from the product to generate the data signal
    assign carry0       = prod[2*DELAY_WIDTH - 1];
    assign carry1       = prod[2*DELAY_WIDTH - 2];
    assign carry2       = prod[2*DELAY_WIDTH - 3];
    assign carry3       = prod[2*DELAY_WIDTH - 4];
    assign data_comb         = {(LOAD_WORDS*WORD_WIDTH/4){carry3, carry2, carry1, carry0}};  
    
    // Create a register to create an endpoint inside of memory
    always @(posedge clk) begin
        mem <= (mem << 1) | addr;
        data_ff <= stall ? data_ff : data_comb;
    end

    assign data = (PIPELINED!=0)?data_ff:data_comb;
        
endmodule: fake_memory_delay

`endif /* !SIMULATION_18447 */
