/**
 * riscv_core.sv
 *
 * RISC-V 32-bit Processor
 *
 * ECE 18-447
 * Carnegie Mellon University
 *
 * This is the core part of the processor, and is responsible for executing the
 * instructions and updating the CPU state appropriately.
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

/* A quick switch to enable/disable tracing. Comment out to disable. Please
 * comment this out before submitting your code. You'll also want to comment
 * this out for longer tests, as it will make them run much faster. */
`define TRACE

// Force the compiler to throw an error if any variables are undeclared
`default_nettype none

//Specify which branch predictor counter to use (0, 1, 2 bit)
parameter BP_BITS = 3; 

/**
 * The core of the RISC-V processor, everything except main memory.
 *
 * This is the RISC-V processor, which, each cycle, fetches the next
 * instruction, executes it, and then updates the register file, memory,
 * and register file appropriately.
 *
 * The memory that the processor interacts with is dual-ported with a
 * single-cycle synchronous write and combinational read. One port is used to
 * fetch instructions, while the other is for loading and storing data.
 *
 * Inputs:
 *  - clk               The global clock for the processor.
 *  - rst_l             The asynchronous, active low reset for the processor.
 *  - instr_mem_excpt   Indicates that an invalid instruction address was given
 *                      to memory.
 *  - data_mem_excpt    Indicates that an invalid address was given to the data
 *                      memory during a load and/or store operation.
 *  - dcache_ready      Indicates that the dcache is ready for a request
 *  - icache_ready      Indicates that the icache is ready for a request
 *  - in_instr_addr     The address of the instruction loaded from memory
 *  - instr             The instruction loaded from memory
 *  - data_load         The data loaded from the data_addr address in memory.
 *
 * Outputs:
 *  - data_load_en      Indicates that data from the data_addr address in
 *                      memory should be loaded.
 *  - halted            Indicates that the processor has stopped because of a
 *                      syscall or exception. Used to indicate to the testbench
 *                      to end simulation. Must be held until next clock cycle.
 *  - data_store_mask   Byte-enable bit mask  signal indicating which bytes of data_store
 *                      should be written to the data_addr address in memory.
 *  - out_instr_addr    The address of the instruction to load from memory.
 *  - data_addr         The address of the data to load or store from memory.
 *  - data_stall        stall data load from memory if multicycle.
 *  - data_store        The data to store to the data_addr address in memory.
 **/
module riscv_core
    (input  logic           clk, rst_l, instr_mem_excpt, data_mem_excpt,
     input  logic           dcache_ready, icache_ready,
     input  logic [29:0]    in_instr_addr,
     input  logic           dcache_read_hit,
     input  logic [31:0]    data_load_fwd,
     input  logic [31:0]    instr, data_load,
     output logic           data_load_en, halted,
     output logic [3:0]     data_store_mask,
     output logic [29:0]    out_instr_addr, data_addr,
     output logic           stall_icache,
     output logic           cancel_instr,
     output  logic          read_instr,
     output logic [31:0]    data_store);

    /* Import the ISA field types, and the argument to ecall to halt the
     * simulator, and the start of the user text segment. */
    import RISCV_ISA::*;
    import RISCV_ABI::ECALL_ARG_HALT;
    import MemorySegments::USER_TEXT_START;

    //instr pipelines
    logic [31:0] instr_D, instr_DE, instr_DEM1, instr_DEM1M2;

    //ctrl_signals pipelines
    ctrl_signals_t ctrl_signals, ctrl_signals_D, ctrl_signals_DE,
                    ctrl_signals_DEM1, ctrl_signals_DEM1M2;

    //imm pipeline
    logic [31:0] imm, imm_D;

    //rs1_data pipeline
    logic [31:0] rs1_data, rs1_data_D;

    //alu_out pipeline
    logic [31:0] alu_out, alu_out_E, alu_out_EM1, alu_out_EM1M2, alu_out_EM1M2W;

    //rs2_data pipeline/used for ecall
    logic [31:0] rs2_data, rs2_data_D, rs2_data_DE, rs2_data_DEM1, rs2_data_DEM1M2;

    //mux output between decode stage and fwded signals
    logic [31:0] rs1_data_DEM1M2W, rs2_data_DEM1M2W;
    logic [31:0] data_load_masked, data_load_fwd_masked;

    //write back signals
    logic [31:0] rd_data_W;
    logic [4:0] rd_W;

    //pc pipeline
    logic [31:0] pc, pc_F1, pc_F1F2, pc_FD, pc_FDE, pc_FDEM1, pc_FDEM1M2;

    //pc/instr bubbles for IF/ID
    logic [31:0] pc_bubble, pc_bubble_F1, instr_bubble_F;

    //bubbles for ID/EX
    logic [31:0] instr_bubbles;
    ctrl_signals_t ctrl_signals_bubbles;
    logic [31:0] rs2_data_bubbles, pc_bubbles_F1F2, rs1_data_bubbles, imm_bubbles;

    //bubbles for MEM1/MEM2
    logic [31:0] instr_bubbles_DE;
    ctrl_signals_t ctrl_signals_bubbles_DE;
    logic [31:0] alu_out_bubbles_E, rs2_data_bubbles_DE, pc_bubbles_FDE;

    //bubbles for start of WB stage
    logic [31:0] instr_bubbles_DEM1;
    ctrl_signals_t ctrl_signals_bubbles_DEM1;
    logic [31:0] alu_out_bubbles_DEM1, rs2_data_bubbles_DEM1, pc_bubbles_FDEM1;

    //enable signal on F1F2 stages for instr cache miss stalls
    logic F1F2en;
    //enable signal on F2ID stages for RAW stalls
    logic F2IDen;
    //enable signal on IDEX stages for data cache not ready stalls
    logic IDEXen;
    //enable signal on EXMEM1 stages for data cache not ready stalls
    logic EXMEM1en;
    //enable signal on MEM2 stage for data cache miss stalls
    logic MEM2en;

    //loadAdd dependency detection
    logic loadAdd;

    //ctrl logic on flush + pipelined flush
    logic rewind, rewind_E;

    //bcond is result of branch in EX
    logic bcond, bcond_E;

    //pipelined pc for ctrl flow
    logic [31:0] rewind_PC, rewind_PC_E;
    //the target PC (data) to write back to the BTB
    logic [31:0] btb_wdata_PC, btb_wdata_PC_E;

    //if current instruction in MEM1 is ctrlflow / branch
    logic isCtrlFlow_E, isBranch_E, isJump_E;
    //write enable the btb, update the branch predictor
    logic write_btb, update_bp;

    //if we predicted taken in F1
    logic pred_taken;
    //1 if hit in btb, 0 if miss, x if rewind, so BTB is not read
    logic btb_hit, btb_hit_F1, btb_hit_F1F2, btb_hit_F1F2D;
    logic [31:0] btb_fetched_pc;

    //ltched dcache / icache ready signals for stalling icache
    logic ltched_icache_ready;

    //these signals control the muxes for which val of rs1 / rs2 to EX
    logic fwd_alu_out_rs1, fwd_alu_out_rs2;
    logic fwd_alu_out_rs1_E, fwd_alu_out_rs2_E;
    logic fwd_alu_out_rs1_M1, fwd_alu_out_rs2_M1;
    logic fwd_mem_out_rs1_M1, fwd_mem_out_rs2_M1;
    logic fwd_alu_out_rs1_M2, fwd_alu_out_rs2_M2;
    logic fwd_mem_out_rs1_M2, fwd_mem_out_rs2_M2;

    logic instr_stall;

    //forward detection unit + load/add dependency detect
    forwardDetection fd
        (.dcache_read_hit,
        .instr, .instr_D, .instr_DE, .instr_DEM1, .instr_DEM1M2,
        .ctrl_signals, .ctrl_signals_D,
        .ctrl_signals_DE, .ctrl_signals_DEM1, .ctrl_signals_DEM1M2,
        .fwd_alu_out_rs1, .fwd_alu_out_rs2,
        .fwd_alu_out_rs1_E, .fwd_alu_out_rs2_E,
        .fwd_alu_out_rs1_M1, .fwd_alu_out_rs2_M1,
        .fwd_mem_out_rs1_M1, .fwd_mem_out_rs2_M1,
        .fwd_alu_out_rs1_M2, .fwd_alu_out_rs2_M2,
        .fwd_mem_out_rs1_M2, .fwd_mem_out_rs2_M2,
        .loadAdd);


    //flushing asserted on rewind_E, ONLY deasserted when rewind PC reaches F2 
    logic flushing;

    //logic for stalling icache (when dcache is not yet ready)
    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            ltched_icache_ready <= 1'b0;
        end 
        else begin
            ltched_icache_ready <= icache_ready;
        end
    end

    /*
    If instr_addr is not 0 (we have an instr ready in ID), and
    instr_addr matches the pc in F2, misaligned! stall icache until pc is no
    longer in F2 (has moved on to ID). 

    If ~IDEXen, ID pc + instr will not get ltched into EX stage, stall.
    If loadAdd, blowing bubbles into ID/EX regs, stall.
    */
    assign stall_icache = (((in_instr_addr != 'b0) && (in_instr_addr == pc_F1[31:2]))
                            | (~IDEXen | loadAdd));


    enum logic [1:0] {NOT_FLUSHING, REWIND_PC_IN_F1, REWIND_PC_IN_F2} 
                flush_state, flush_nextstate;

    always_ff @(posedge clk) begin
        if (~rst_l)
            flush_state <= NOT_FLUSHING;
        else
            flush_state <= flush_nextstate;
    end

    always_comb begin
        flush_nextstate = flush_state;
        flushing = 1'b0; //default case
        cancel_instr = 1'b0;
        read_instr = 1'b1;
        if (flush_state == NOT_FLUSHING) begin
            if (rewind_E) begin
                flush_nextstate = REWIND_PC_IN_F1;
                flushing = 1'b1; //begin to flush
                cancel_instr = 1'b1; //cancel in-flight invalid instr
                read_instr = 1'b0; //do not read from invalid PC
            end
            else begin
                flush_nextstate = NOT_FLUSHING;
                flushing = 1'b0; //no rewind, not flushing
                cancel_instr = 1'b0; //no rewind, assume in-flight instr valid
                read_instr = 1'b1; //no rewind, assume PC is valid
            end
        end
        else if (flush_state == REWIND_PC_IN_F1) begin
            //the cycle after rewind_E, bubble is blown into F2
            //rewind PC in F1 the cycle after rewind_E (make read request)
            flush_nextstate = REWIND_PC_IN_F2;
            flushing = 1'b1; //flushing for third cycle
            cancel_instr = 1'b0; //no in-flight instr, do not cancel
            read_instr = 1'b1; //read from rewind PC
        end
        else if (flush_state == REWIND_PC_IN_F2) begin
            //bubble propagated from F2 to ID, done flushing all invalid instrs
            flush_nextstate = NOT_FLUSHING;
            flushing = 1'b0; //done flushing
            cancel_instr = 1'b0; //no in-flight instr, do not cancel
            read_instr = 1'b1; //read from valid PC
        end
    end
    /*
    Invariant: on rewind_E, PCs in F1, F2, ID are invalid, so F1F2en and 
    F2IDen throughout the flushing process
    if a load is in MEM2, and dcache not ready, cache miss! stall at MEM2
    if a load is in MEM1, and dcache not ready, stall at MEM1
    if loadAdd dependency, or the , stall at ID
    if icache not ready, stall at F2
    */
    always_comb begin
        {F1F2en, F2IDen, IDEXen, EXMEM1en, MEM2en, instr_stall} = 5'b11110;
        if ((instr_DEM1[6:0] == OP_LOAD) && (~dcache_ready)) begin //stall at MEM2
            {F1F2en, F2IDen, IDEXen, EXMEM1en, MEM2en, instr_stall} = {flushing, flushing, 4'b0001};
        end
        else if (loadAdd) begin //stall at ID
            {F1F2en, F2IDen, IDEXen, EXMEM1en, MEM2en, instr_stall} = {flushing, flushing, 4'b1111};
        end
        else if ((~icache_ready)) begin //stall at F2
            {F1F2en, F2IDen, IDEXen, EXMEM1en, MEM2en, instr_stall} = {flushing, 5'b11111};
        end
        else begin //no stalling
            {F1F2en, F2IDen, IDEXen, EXMEM1en, MEM2en, instr_stall} = 6'b111110;
        end
    end

    logic ltched_EXMEM1en;
    logic ltched_MEM2en;
    //latch the EXMEM1en to tell execute stage to stop rewinding if stalled
    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            ltched_EXMEM1en <= 1'b1;
            ltched_MEM2en <= 1'b1;
        end 
        else begin
            ltched_EXMEM1en <= EXMEM1en;
            ltched_MEM2en <= MEM2en;
        end
    end



    //fetch stage
    instructionFetch IFStage
        (.clk, .rst_l, .halted, .F1F2en, .out_instr_addr, .pc,
        .rewind(rewind_E), .rewind_pc(rewind_PC_E), 
        .waddr_pc(pc_FDE), .wdata_pc(btb_wdata_PC_E),
        .write_btb, .isJump_E, .pred_taken, .btb_hit);

    //branch predictor unit, only enable if MEM1 has a branch
    //branch is resolved in EX, but pipelined so we only check in MEM1
    branchPredictor #(BP_BITS) bp (.clk, .rst_l, .update_bp,
                                .taken(bcond_E), .pred_taken, .mispredict(rewind_E),
                                .fetch_pc(pc), .exec_pc(pc_FDE));

    //if flushing, then inject bubble
    assign pc_bubble = (rewind_E) ? 'b0 : pc;

    /****       F1/F2 pipeline regs     ****/
    register #($bits(pc)) FIF2pc
        (.clk, .rst_l, .en(F1F2en), .clear(1'b0), .D(pc_bubble), .Q(pc_F1));

    register #($bits(btb_hit)) F1F2_btb_hit
        (.clk, .rst_l, .en(F1F2en), .clear(1'b0), .D(btb_hit), .Q(btb_hit_F1));


    //flushing for F1F2 pc, when rewind or when icache not ready (~F1F2en)
    assign pc_bubble_F1 = (F1F2en && (~rewind_E)) ? pc_F1: 'b0;


    /****       F2/ID pipeline regs     ****/
    register #($bits(pc)) F2IDpc
        (.clk, .rst_l, .en(F2IDen), .clear(1'b0), .D(pc_bubble_F1), .Q(pc_F1F2));

    register #($bits(btb_hit)) F2ID_btb_hit
        (.clk, .rst_l, .en(F2IDen), .clear(1'b0), .D(btb_hit_F1), .Q(btb_hit_F1F2));

    

    //flushing for instr from F
    //assign instr_bubble_F = (rewind_E) ? 'b0 : instr;

    //decode stage
    instructionDecode IDStage
        (.clk, .rst_l,
         .rd_data(rd_data_W), .rd_in(rd_W), .ctrl_signalsWB(ctrl_signals_DEM1M2),
         .instr, .rs1_data, .rs2_data, .imm, .ctrl_signals, .halted);

    //byteMasking data_load before forwarding to decode
    byteMask bm_fwd
        (.data_load(data_load_fwd),
         .ctrl_signals(ctrl_signals_DEM1), //MEM2 ctrl signals
         .alu_out(alu_out_EM1), //MEM2 alu_out
         .rd_data(data_load_fwd_masked));

    byteMask bm
        (.data_load(data_load),
         .ctrl_signals(ctrl_signals_DEM1M2), //WB ctrl signals
         .alu_out(alu_out_EM1M2), //WB alu_out
         .rd_data(data_load_masked));

    //Mux on the rs1_data from decode stage or fwded
    always_comb begin
        if (fwd_alu_out_rs1)
            rs1_data_DEM1M2W = alu_out; //use alu_out at end of EX stage
        else if (fwd_alu_out_rs1_E)
            rs1_data_DEM1M2W = alu_out_E; //use alu_out_E stored in EX/MEM1 reg
        else if (fwd_alu_out_rs1_M1)
            rs1_data_DEM1M2W = alu_out_EM1; //use alu_out_EM1 stored in MEM1/MEM2 reg
        else if (fwd_mem_out_rs1_M1)
            rs1_data_DEM1M2W = data_load_fwd_masked; //data_load masked in bm
        else if (fwd_alu_out_rs1_M2)
            rs1_data_DEM1M2W = alu_out_EM1M2; //use alu_out_EM1M2 stored in MEM2/WB reg
        else if (fwd_mem_out_rs1_M2)
            rs1_data_DEM1M2W = data_load_masked; //data_load masked in bm
        else
            rs1_data_DEM1M2W = rs1_data;
    end
    //Mux on the rs2_data coming from decode stage or fwded
    always_comb begin
        if (fwd_alu_out_rs2)
            rs2_data_DEM1M2W = alu_out; //use alu_out at end of EX stage
        else if (fwd_alu_out_rs2_E)
            rs2_data_DEM1M2W = alu_out_E; //use alu_out_E stored in EX/MEM1 reg
        else if (fwd_alu_out_rs2_M1)
            rs2_data_DEM1M2W = alu_out_EM1; //use alu_out_EM1 stored in MEM1/MEM2 reg
        else if (fwd_mem_out_rs2_M1)
            rs2_data_DEM1M2W = data_load_fwd_masked; //data_load masked in bm
        else if (fwd_alu_out_rs2_M2)
            rs2_data_DEM1M2W = alu_out_EM1M2; //use alu_out_EM1M2 stored in MEM2/WB reg
        else if (fwd_mem_out_rs2_M2)
            rs2_data_DEM1M2W = data_load_masked; //data_load masked in bm
        else
            rs2_data_DEM1M2W = rs2_data;
    end

    logic ID_not_bubbles;
    assign ID_not_bubbles = (F2IDen && ~rewind && ~rewind_E && (pc_F1F2 != 'b0));
    //IDEX pipeline signal bubble muxes
    //when ~EXMEM1, bubbles blown at MEM1 instead
    //bubbles at ID/EX will not be ltched, so this is safe
    assign instr_bubbles = ID_not_bubbles ? instr : 32'b0;
    assign ctrl_signals_bubbles = ID_not_bubbles ? ctrl_signals : 24'b0;
    assign rs2_data_bubbles = ID_not_bubbles ? rs2_data_DEM1M2W: 32'b0;
    assign pc_bubbles_F1F2 = ID_not_bubbles ? pc_F1F2 : 32'b0;
    assign rs1_data_bubbles = ID_not_bubbles ? rs1_data_DEM1M2W : 32'b0;
    assign imm_bubbles = ID_not_bubbles ? imm : 32'b0;


    /****       ID/EX pipeline regs     ****/
    register #($bits(ctrl_signals),
    {6'b000000, IMM_DC, ALU_DC, LDST_DC, 1'b0, 3'b0, 1'b0, 1'b0}) IDEXctrl
        (.clk, .rst_l, .en(IDEXen), .clear(1'b0), .D(ctrl_signals_bubbles), .Q(ctrl_signals_D));
    register #($bits(instr)) IDEXinstr
        (.clk, .rst_l, .en(IDEXen), .clear(1'b0), .D(instr_bubbles), .Q(instr_D));
    register #($bits(rs1_data)) IDEXrs1
        (.clk, .rst_l, .en(IDEXen), .clear(1'b0), 
                                        .D(rs1_data_bubbles), .Q(rs1_data_D));
    register #($bits(rs2_data)) IDEXrs2
        (.clk, .rst_l, .en(IDEXen), .clear(1'b0), 
                                        .D(rs2_data_bubbles), .Q(rs2_data_D));
    register #($bits(imm)) IDEXimm
        (.clk, .rst_l, .en(IDEXen), .clear(1'b0), .D(imm_bubbles), .Q(imm_D));
    register #($bits(pc)) IDEXpc
        (.clk, .rst_l, .en(IDEXen), .clear(1'b0), .D(pc_bubbles_F1F2), .Q(pc_FD));
    register #($bits(btb_hit)) IDEX_btb_hit
        (.clk, .rst_l, .en(IDEXen), .clear(1'b0), .D(btb_hit_F1F2), .Q(btb_hit_F1F2D));


    /*
    Two cases for btb_fetched_pc:
    1. btb_fetched_pc is one stage behind branch instr (pull from ID)
    2. btb_fetched_pc is two stages behind branch instr (pull from F2)
    
    Case 1 happens when there is no icache miss, the dist remains as 1
    (the dist can only go to 2 when icache miss, and NO dcache stall.
    if icache miss AND dcache stall, both instrs stalled, so dist = 1 still)
    Case 2 is when an icache miss happens, and bubble is inserted between.

    When branch in EX, check if there was an icache miss in the last
    cycle. This is indicated by ~ltched_icache_ready. If there was, pull
    from F2. Otherwise pull from ID.
    */
    assign btb_fetched_pc = (ltched_icache_ready) ? pc_F1F2 : pc_F1;

    //execute stage (btb_fetched_pc_F1F2 refers to the pc in the PREV stage)
    //that is the pc in Decode, which is the target pc fetched from BTB
    execute exeStage (
        .ctrl_signals(ctrl_signals_D), .ltched_EXMEM1en,
        .rs2_data(rs2_data_D),
        .rs1_data(rs1_data_D), .imm(imm_D), .pc(pc_FD), 
        .btb_fetched_pc(btb_fetched_pc), 
        .alu_out, .rewind, .bcond, .rewind_pc(rewind_PC), 
        .npc_offset(btb_wdata_PC));

    /****       EX/MEM1 pipeline regs     ****/
    register #($bits(ctrl_signals), {6'b000000, IMM_DC, ALU_DC, LDST_DC, 1'b0, 3'b0, 1'b0, 1'b0}) EXMEMctrl
        (.clk, .rst_l, .en(EXMEM1en), .clear(1'b0), .D(ctrl_signals_D), .Q(ctrl_signals_DE));
    register #($bits(instr)) EXMEMinstr
        (.clk, .rst_l, .en(EXMEM1en), .clear(1'b0), .D(instr_D), .Q(instr_DE));
    register #($bits(rs2_data)) EXMEMrs2
        (.clk, .rst_l, .en(EXMEM1en), .clear(1'b0), .D(rs2_data_D), .Q(rs2_data_DE));
    register #($bits(alu_out)) EXMEMalu
        (.clk, .rst_l, .en(EXMEM1en), .clear(1'b0), .D(alu_out), .Q(alu_out_E));
    register #($bits(pc)) EXMEMpc
        (.clk, .rst_l, .en(EXMEM1en), .clear(1'b0), .D(pc_FD), .Q(pc_FDE));

    //these signals do not go to MEM1 stage, always latch (needed to flush)
    register #($bits(rewind)) EXMEMrewind
        (.clk, .rst_l, .en(1'b1), .clear(1'b0), .D(rewind), .Q(rewind_E));
    register #($bits(bcond)) EXMEMbcond
        (.clk, .rst_l, .en(1'b1), .clear(1'b0), .D(bcond), .Q(bcond_E));
    register #($bits(rewind_PC_E)) EXMEMrewind_pc
        (.clk, .rst_l, .en(1'b1), .clear(1'b0), .D(rewind_PC), .Q(rewind_PC_E));
    register #($bits(btb_wdata_PC_E)) EXMEMbtb_write_pc
        (.clk, .rst_l, .en(1'b1), .clear(1'b0), .D(btb_wdata_PC), .Q(btb_wdata_PC_E));


    //ctrlflow instr in MEM1
    assign isCtrlFlow_E = (ctrl_signals_DE.pc_source == PC_cond) |
                            (ctrl_signals_DE.pc_source == PC_uncond) |
                            (ctrl_signals_DE.pc_source == PC_indirect);
    //branch instr in MEM1
    assign isBranch_E = (ctrl_signals_DE.pc_source == PC_cond);

    //jump instr in MEM1
    assign isJump_E = (ctrl_signals_DE.pc_source == PC_uncond) |
                       (ctrl_signals_DE.pc_source == PC_indirect);

    //if ctrlflow instr in MEM1, and MEM1/MEM2 not stalled last cycle
    assign write_btb = isCtrlFlow_E && ltched_MEM2en;
    assign update_bp = isBranch_E && ltched_MEM2en;

    //MEM1 stage
    mem memStage
        (.rs2_data(rs2_data_DE), .data_load_en,
         .ctrl_signals(ctrl_signals_DE), .data_addr,
         .data_store_mask, .data_store, .alu_out(alu_out_E));

     /****       MEM1/MEM2 pipeline regs     ****/
    register #($bits(ctrl_signals)) MEM1_MEM2ctrl
        (.clk, .rst_l, .en(MEM2en), .clear(1'b0),
            .D(ctrl_signals_DE), .Q(ctrl_signals_DEM1));
    register #($bits(instr)) MEM1_MEM2instr
        (.clk, .rst_l, .en(MEM2en), .clear(1'b0), .D(instr_DE), .Q(instr_DEM1));
    register #($bits(alu_out)) MEM1_MEM2alu
        (.clk, .rst_l, .en(MEM2en), .clear(1'b0), .D(alu_out_E), .Q(alu_out_EM1));
    register #($bits(pc)) MEM1_MEM2pc
        (.clk, .rst_l, .en(MEM2en), .clear(1'b0), .D(pc_FDE), .Q(pc_FDEM1));
    register #($bits(rs2_data)) MEM1_MEM2rs2_data
        (.clk, .rst_l, .en(MEM2en), .clear(1'b0), .D(rs2_data_DE), .Q(rs2_data_DEM1));

    //if load at MEM2 stage, expect dcache_ready to be asserted
    //if not asserted, cache miss! stall the pipeline, insert bubbles
    assign ctrl_signals_bubbles_DEM1 = (MEM2en) ? ctrl_signals_DEM1 : 24'd0;
    assign instr_bubbles_DEM1 = (MEM2en) ? instr_DEM1 : 32'd0;
    assign alu_out_bubbles_DEM1 = (MEM2en) ? alu_out_EM1 : 32'd0;
    assign pc_bubbles_FDEM1 = (MEM2en) ? pc_FDEM1 : 32'd0;
    assign rs2_data_bubbles_DEM1 = (MEM2en) ? rs2_data_DEM1 : 32'd0;


    /****       MEM2/WB pipeline regs     ****/
    register #($bits(ctrl_signals)) MEM2_Wctrl
        (.clk, .rst_l, .en(1'b1), .clear(1'b0),
            .D(ctrl_signals_bubbles_DEM1), .Q(ctrl_signals_DEM1M2));
    register #($bits(instr)) MEM2_Winstr
        (.clk, .rst_l, .en(1'b1), .clear(1'b0), .D(instr_bubbles_DEM1), .Q(instr_DEM1M2));
    register #($bits(alu_out)) MEM2_Walu
        (.clk, .rst_l, .en(1'b1), .clear(1'b0), .D(alu_out_bubbles_DEM1), .Q(alu_out_EM1M2));
    register #($bits(pc)) MEM2_Wpc
        (.clk, .rst_l, .en(1'b1), .clear(1'b0), .D(pc_bubbles_FDEM1), .Q(pc_FDEM1M2));
    register #($bits(rs2_data)) MEM2_Wrs2_data
        (.clk, .rst_l, .en(1'b1), .clear(1'b0), .D(rs2_data_bubbles_DEM1), .Q(rs2_data_DEM1M2));


    //WB stage (data_load is generated at start of WB stage)
    wb wbStage
        (.instr(instr_DEM1M2), .data_load(data_load),
         .ctrl_signals(ctrl_signals_DEM1M2), .alu_out(alu_out_EM1M2),
         .rd_data(rd_data_W), .rd_out(rd_W), .pc(pc_FDEM1M2));

    //syscall managing
    syscallDetect sd(.*);

endmodule: riscv_core


