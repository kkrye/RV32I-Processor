`default_nettype none

// RISC-V Includes
`include "riscv_abi.vh"             // ABI registers and definitions
`include "riscv_isa.vh"             // RISC-V ISA definitions
`include "memory_segments.vh"       // Memory segment starting addresses

// Local Includes
`include "internal_defines.vh"      // Control signals struct, ALU ops

parameter BTB_SIZE = 128; //custom size of BTB
parameter BTB_ADDR_BITS = $clog2(BTB_SIZE);

/**
* Instruction Fetch stage
* pipeline stage that includes pc+4 calculation
* rewind signal controls flushing and
* new pc fetch from correct pc location on ctrlFlow
* waddr_pc is the PC of the resolved branch
* wdata_pc is the target PC of the resolved branch
**/
module instructionFetch(
    input logic clk, rst_l,
    input logic halted,
    input logic F1F2en,
    input logic rewind,
    input logic write_btb,
    input logic isJump_E,
    input logic pred_taken,
    output logic btb_hit,
    input logic [31:0] rewind_pc,
    input logic [31:0] waddr_pc, wdata_pc,
    output logic [29:0] out_instr_addr,
    output logic [31:0] pc);

    //pc signals
    logic [31:0] next_pc, npc_plus4;
    logic [61:0] read_data, write_data; //assuming 62-bit default
    logic [31:0] tag_pc; 
    logic [1:0] history; //unused for now, using counters to predict instead
    logic [31:0] btb_target_pc;
    logic fetched_jump; //if fetched jump, use target pc
    import MemorySegments::USER_TEXT_START;

    //next_pc and btb_hit logic
    always_comb begin
        if (rewind) begin//rewind takes priority over everything else
            next_pc = rewind_pc; 
            btb_hit = 1'bx; //don't read from the BTB, so not a hit / miss
        end
        else if (tag_pc == pc) begin//branch exists in BTB
            if (fetched_jump | pred_taken) begin
                next_pc = btb_target_pc; //predict taken, use BTB pc
            end
            else begin
                next_pc = npc_plus4; //predict not taken, don't use BTB pc
            end
            btb_hit = 1'b1; //hit
        end
        else begin
            next_pc = npc_plus4;
            btb_hit = 1'b0; //miss
        end
    end

    register #($bits(pc), USER_TEXT_START) PC_register(.clk, .rst_l,
        .en(F1F2en && ~halted), .clear(1'b0), .D(next_pc), .Q(pc));

    assign npc_plus4 = pc + 4;

    //alignment
    assign out_instr_addr = pc[31:2];

    //if MEM1 instr is ctrlflow (jump / branch), write target PC into BTB 
    //read_addr / write_addr are lower N bits of the pc
    sram_1r_1w #(.NUM_WORDS(BTB_SIZE)) sram(.clk, .rst_l, 
                                            .we(write_btb), 
                                            .read_addr(pc[BTB_ADDR_BITS-1:0]), 
                                            .write_addr(waddr_pc[BTB_ADDR_BITS-1:0]),
                                            .write_data(write_data), 
                                            .read_data(read_data));

    //form the write_data, set bit to indicate if it was a jump
    assign write_data = {waddr_pc[31:2], 1'd0, isJump_E, wdata_pc[31:2]};

    //Format: {tagPC[31:2], 1'd0, wasJump, nextPC[31:2]}
    assign tag_pc = {read_data[61:32], 2'd0};
    assign fetched_jump = read_data[30];
    assign btb_target_pc = {read_data[29:0], 2'd0};


endmodule : instructionFetch


/**
* Decode stage
* immediate parsing based on type
* register file reading/writing
* write back signals received from WB stage
**/
module instructionDecode(
    input logic clk, rst_l, halted,
    input logic [31:0] rd_data, instr,
    input logic [4:0] rd_in,
    input ctrl_signals_t ctrl_signalsWB,
    output logic [31:0] rs1_data, rs2_data, imm,
    output ctrl_signals_t ctrl_signals);

    //decoder
    riscv_decode Decoder(.rst_l, .instr, .ctrl_signals);

    //RF
    logic [4:0] rs1, rs2;
    assign rs1 = instr[19:15];
    assign rs2 = (ctrl_signals.syscall) ? 5'd10 : instr[24:20];

    register_file #(.FORWARD(1)) reg_file (.rd_we(ctrl_signalsWB.rfWrite), .rd(rd_in), .*);

    //imm
    logic [31:0] s_immediate, i_immediate, u_immediate, boffset, joffset;
    //S-type immediate
    assign s_immediate={{21{instr[31]}},instr[30:25],instr[11:7]};
    //I-type immediate
    assign i_immediate={{21{instr[31]}},instr[30:20]};
    //U-type immediate
    assign u_immediate={instr[31:12], 12'b0};
    //boffset is for B-type immediate
    assign boffset={{20{instr[31]}},instr[7],instr[30:25],instr[11:8],1'b0};
    //joffset is for J-type immediate
    assign joffset={{12{instr[31]}},instr[19:12],instr[20],instr[30:21], 1'b0};

    always_comb begin
        unique case (ctrl_signals.imm_mode)
            IMM_I: imm = i_immediate;
            IMM_U: imm = u_immediate;
            IMM_S: imm = s_immediate;
            IMM_UJ: imm = joffset;
            IMM_SB: imm = boffset;
            default: imm = 'bx;
        endcase
    end
endmodule : instructionDecode

/**
* Execute stage
* includes ALU, branch calculation and
* mux based on pcsrc
* ALU only calculates for the rd of an instruction
* Offset_PC_Adder only calculates for the next_PC of an instruction
**/
module execute(
    input ctrl_signals_t ctrl_signals,
    input logic ltched_EXMEM1en,
    input logic [31:0] rs2_data, rs1_data, imm, pc, 
    input logic [31:0] btb_fetched_pc,
    output logic [31:0] alu_out,
    output logic rewind,
    output logic bcond,
    output logic [31:0] rewind_pc, npc_offset); 
    //npc_offset is the target PC of an branch / JAL (PC += imm)

    logic [31:0] ctrlflow_base;
    logic [31:0] npc_plus4;
    logic [31:0] alu_src1;
    logic [31:0] alu_src2;
    //imm mux for alu_src1
    always_comb begin
        if (ctrl_signals.auipc | ctrl_signals.pc_source == PC_uncond |
            ctrl_signals.pc_source == PC_indirect) 
            //auipc instr, rd = pc + (imm << 12) or JAL/JALR, rd = pc + 4
            alu_src1 = pc;
        else if (ctrl_signals.imm_mode == IMM_U) //lui instr, 0 + (imm << 12)
            alu_src1 = 32'd0;
        else
            alu_src1 = rs1_data;
    end

    //ctrl logic
    always_comb begin
        if (~ltched_EXMEM1en) begin
            //EX stage stalled in prev cycle, don't rewind twice.
            rewind_pc = 'bx;
            rewind = 1'b0;
        end
        else begin
            unique case (ctrl_signals.pc_source)
            //branch (PC += imm)
                PC_cond: begin
                    if (bcond && (btb_fetched_pc != npc_offset)) begin
                        //if not fetched from BTB, must have fetched PC + 4
                        //since branch taken, pipeline needs to be flushed
                        rewind_pc = npc_offset;
                        rewind = 1'b1;
                    end 
                    else if (~bcond && (btb_fetched_pc == npc_offset)) begin
                        //if fetched from BTB, must have fetched cached PC
                        //since branch not taken, pipeline needs to be flushed
                        rewind_pc = npc_plus4;
                        rewind = 1'b1;
                    end 
                    else begin //correct prediction, don't flush
                        rewind_pc = 'bx;
                        rewind = 1'b0;
                    end
                end
            //jal (PC += imm) or jalr (PC = rs1 + imm)
                PC_uncond: begin
                    if (btb_fetched_pc == npc_offset) begin
                        //BTB fetched pc is equal to target pc, pipeline is correct
                        rewind_pc = 'bx;
                        rewind = 1'b0;
                    end
                    else begin
                        //otherwise flush pipeline
                        rewind_pc = npc_offset;
                        rewind = 1'b1;
                    end
                end
                PC_indirect: begin
                    if (btb_fetched_pc == npc_offset) begin
                        //BTB fetched pc is equal to target pc, pipeline is correct
                        rewind_pc = 'bx;
                        rewind = 1'b0;
                    end
                    else begin
                        //otherwise flush pipeline
                        rewind_pc = npc_offset;
                        rewind = 1'b1;
                    end
                end
                default: begin
                    rewind_pc = 'bx;
                    rewind = 1'b0;
                end
            endcase
        end
    end

    //ctrlflow_base is the first operand of a PC calculation
    //Branch and JAL have next_pc = PC + imm, JALR has next_pc = rs1 + imm
    assign ctrlflow_base = (ctrl_signals.pc_source == PC_indirect) 
                            ? rs1_data : pc;

    assign npc_offset = ctrlflow_base + imm;

    assign npc_plus4 = pc + 4;

    always_comb begin
        if (ctrl_signals.pc_source == PC_uncond |
            ctrl_signals.pc_source == PC_indirect) begin
                alu_src2 = 4; //if JAL / JALR, alu_out = PC + 4
            end
        else if (ctrl_signals.useImm) //all imm instrs except JAL / JALR
            alu_src2 = imm;
        else
            alu_src2 = rs2_data;
    end

    //alu
    riscv_alu ALU(.alu_src1(alu_src1), .alu_src2(alu_src2),
        .alu_op(ctrl_signals.alu_op), .alu_out(alu_out), .bcond_out(bcond), .ctrl_signals);

endmodule : execute

/**
* Mem1 stage
* ldst store mask generation
* feeds addr into data_mem
**/
module mem(
    input logic [31:0] rs2_data, alu_out,
    input ctrl_signals_t ctrl_signals,
    output logic [29:0] data_addr,
    output logic data_load_en,
    output logic [3:0] data_store_mask,
    output logic [31:0] data_store);

    logic [4:0] data_addr_offset;
    assign data_load_en     = ctrl_signals.memRead;

    //Perform any needed memory accesses for the instruction.
    assign data_addr        = alu_out[31:2]; //aligned to word boundary
    assign data_addr_offset = {3'b000, alu_out[1:0]};

    assign data_store = rs2_data << (data_addr_offset << 3);

    //ldst -> could mess with forwarding
    //Generate byte-enable mask for store instructions
    always_comb begin
        if (ctrl_signals.memWrite) begin
            unique case (ctrl_signals.ldst_mode)
                LDST_W: data_store_mask = 4'b1111;
                LDST_H: data_store_mask = (data_addr_offset[1]) ? 4'b1100 : 4'b0011;
                LDST_B: data_store_mask = (4'b0001 << data_addr_offset);
                default: data_store_mask = 'bx;
            endcase
        end else begin
            data_store_mask = 4'b0000;
        end
    end
endmodule : mem

/**
* Write back stage
* load masking and mux
* outputs to ID stage
**/
module wb(
    input logic [31:0] data_load,
    input logic [31:0] instr,
    input logic [31:0] pc,
    input ctrl_signals_t ctrl_signals,
    input logic [31:0] alu_out,
    output logic [31:0] rd_data,
    output logic [4:0] rd_out);

    //reparse rd
    assign rd_out = instr[11:7];

    /********** Load/Store instruction handling **********/

    logic [31:0] load_mask_out;

    byteMask bm
        (.data_load(data_load),
         .ctrl_signals(ctrl_signals),
         .alu_out(alu_out),
         .rd_data(load_mask_out));


     //Load data to reg file
    always_comb begin
        if (ctrl_signals.pc2RF)
            rd_data = pc + 4;
        else if (ctrl_signals.memRead) begin
            rd_data = load_mask_out;
        end else begin
            rd_data = alu_out;
        end
    end

endmodule : wb

