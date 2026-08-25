`default_nettype none

// RISC-V Includes
`include "riscv_abi.vh"             // ABI registers and definitions
`include "riscv_isa.vh"             // RISC-V ISA definitions
`include "memory_segments.vh"       // Memory segment starting addresses

// Local Includes
`include "internal_defines.vh"      // Control signals struct, ALU ops


//overall branch predictor module, defaults to using two-bit hysteresis
//this module is in F1 stage
module branchPredictor #(parameter BP_BITS = 3)
    (input logic clk, rst_l, update_bp,
     input logic taken, mispredict,
     output logic pred_taken,
     
     input logic [31:0] fetch_pc, exec_pc);

    logic two_bit_pred, one_bit_pred, nt_pred, gshare_pred;

    twoBitHysteresis twobit (.clk, .rst_l, .taken, .update_bp,
                            .pred_taken(two_bit_pred));

    oneBit onebit (.clk, .rst_l, .taken, .update_bp,
                    .pred_taken(one_bit_pred));

    not_tage #(.HIST_BITS(8), .ADDR_BITS($clog2(128)), 
        .PHT_SIZE(128), .LHT_SIZE(128))(
        .clk, .rst_l, .fetch_pc, .pred_taken(nt_pred), 
        .update_bp, .exec_pc, .was_taken(taken), 
        .mispredict(mispredict));

    always_comb begin
        if (BP_BITS == 0)
            pred_taken = 1'b0; //0 bit, always predict not taken
        else if (BP_BITS == 1)
            pred_taken = one_bit_pred;
        else if (BP_BITS == 2)
            pred_taken = two_bit_pred;
        else
            pred_taken = nt_pred; 
    end

endmodule : branchPredictor


//two-bit hysteresis counter
module twoBitHysteresis 
    (input logic clk, rst_l, update_bp,
     input logic taken,
     output logic pred_taken);

    enum logic [1:0] {STRONG_TAKEN, WEAK_TAKEN, 
                        WEAK_NOT_TAKEN, STRONG_NOT_TAKEN} state, nextstate;

    always_ff @(posedge clk) begin
        if (~rst_l)
            state <= STRONG_NOT_TAKEN;
        else if (update_bp) //only if update predictor, make state transition
            state <= nextstate;
    end

    always_comb begin
        //default case
        pred_taken = 1'bx;
        nextstate = state;
        if (state == STRONG_TAKEN) begin
            pred_taken = 1'b1;
            if (taken)
                nextstate = STRONG_TAKEN;
            else
                nextstate = WEAK_TAKEN;
        end 
        else if (state == WEAK_TAKEN) begin
            pred_taken = 1'b1;
            if (taken)
                nextstate = STRONG_TAKEN;
            else
                nextstate = STRONG_NOT_TAKEN;
        end if (state == WEAK_NOT_TAKEN) begin
            pred_taken = 1'b0; //pred not taken
            if (taken)
                nextstate = STRONG_TAKEN;
            else
                nextstate = STRONG_NOT_TAKEN;
        end if (state == STRONG_NOT_TAKEN) begin
            pred_taken = 1'b0; //pred not taken
            if (taken)
                nextstate = WEAK_NOT_TAKEN;
            else
                nextstate = STRONG_NOT_TAKEN;
        end
    end

endmodule : twoBitHysteresis

//one-bit prediction counter
module oneBit
    (input logic clk, rst_l, update_bp,
     input logic taken,
     output logic pred_taken);
    
    enum logic {PRED_TAKEN, PRED_NOT_TAKEN} state, nextstate;

    always_ff @(posedge clk) begin
        if (~rst_l)
            state <= PRED_NOT_TAKEN;
        else if (update_bp) //only if update predictor, make state transition
            state <= nextstate;
    end

    always_comb begin
        //default case
        pred_taken = 1'bx;
        nextstate = state;
        if (state == PRED_TAKEN) begin
            pred_taken = 1'b1;
            if (taken)
                nextstate = PRED_TAKEN;
            else
                nextstate = PRED_NOT_TAKEN;
        end
        else if (state == PRED_NOT_TAKEN) begin
            pred_taken = 1'b0; //pred not taken
            if (taken)
                nextstate = PRED_TAKEN;
            else
                nextstate = PRED_NOT_TAKEN;
        end
    end

endmodule : oneBit


//case to note that alu_out / mem_out can be forwarded to both rs1 and rs2
/** Forward signal unit
* inputs instr and ctrl signal from each pipeline stage
* detects fwd needs through comb logic
* outputs loadAdd dependency boolean and
* all fwd signals before latching
* v1 from lecture slides, forward to decode
**/
module forwardDetection (
    input logic dcache_read_hit,
    input logic [31:0] instr, instr_D, instr_DE, instr_DEM1, instr_DEM1M2,
    input ctrl_signals_t ctrl_signals, ctrl_signals_D, ctrl_signals_DE, ctrl_signals_DEM1,
        ctrl_signals_DEM1M2,
    output logic fwd_alu_out_rs1, fwd_alu_out_rs2,
    output logic fwd_alu_out_rs1_E, fwd_alu_out_rs2_E,
    output logic fwd_alu_out_rs1_M1, fwd_alu_out_rs2_M1,
    output logic fwd_mem_out_rs1_M1, fwd_mem_out_rs2_M1,
    output logic fwd_alu_out_rs1_M2, fwd_alu_out_rs2_M2,
    output logic fwd_mem_out_rs1_M2, fwd_mem_out_rs2_M2,
    output logic loadAdd);

    import RISCV_ISA::*;

    //current instr uses RS1/2 fnc
    function logic useRs1 (input logic [6:0] instr);
        if (instr == OP_LUI || instr == OP_AUIPC ||
            instr == OP_JAL || instr == 'b0) useRs1 = 1'b0;
        else useRs1 = 1'b1;
    endfunction

    function logic useRs2 (input logic [6:0] instr);
        if (instr == OP_OP || instr == OP_STORE ||
            instr == OP_BRANCH) useRs2 = 1'b1;
        else useRs2 = 1'b0;
    endfunction

    function logic validALUOut (input logic [6:0] instr);
        if (instr == OP_OP || instr == OP_IMM ||
            instr == OP_LUI || instr == OP_AUIPC ||
            instr == OP_JAL || instr == OP_JALR) validALUOut = 1'b1;
        else validALUOut = 1'b0;
    endfunction

    //boolean signals to clean up logic
    logic [4:0] rs1ID, rs2ID;
    logic useRs1Var, useRs2Var, notReg0Rs1, notReg0Rs2;
    assign rs1ID = instr[19:15]; //consumer is in DEC
    assign rs2ID = instr[24:20]; //consumer is in DEC
    assign useRs1Var = useRs1(instr[6:0]); //consumer is in DEC
    assign useRs2Var = useRs2(instr[6:0]); //consumer is in DEC
    assign notReg0Rs1 = (rs1ID == 0);
    assign notReg0Rs2 = (rs2ID == 0);
    logic valid_alu_out, valid_alu_out_E, valid_alu_out_EM1, valid_alu_out_EM1M2;
    logic valid_mem_out_M1, valid_mem_out_M2;

    //forward in EX
    assign valid_alu_out = validALUOut(instr_D[6:0]);
    //forward in MEM1
    assign valid_alu_out_E = validALUOut(instr_DE[6:0]);

    //forward in MEM2
    assign valid_alu_out_EM1 = validALUOut(instr_DEM1[6:0]);

    //forward in WB
    assign valid_alu_out_EM1M2 = validALUOut(instr_DEM1M2[6:0]);

    //forward in MEM2 (LOAD)
    assign valid_mem_out_M1 = (instr_DEM1[6:0] == OP_LOAD);

    //forward in WB (LOAD)
    assign valid_mem_out_M2 = (instr_DEM1M2[6:0] == OP_LOAD);

    //syscall detected in decode, following stage has rd as x10 and rfWrite
    function logic syscallFwd
        (input logic [31:0] instr,
            input ctrl_signals_t ctrl_signals_stage);
        if (ctrl_signals.syscall && (instr[11:7] == 'd10) && //stage instr rd == 10
            ctrl_signals_stage.rfWrite)
            syscallFwd = 1'b1;
        else syscallFwd = 1'b0;
    endfunction

    always_comb begin
        /*****  FORWARDING ALU_OUT FROM EX    *****/
        fwd_alu_out_rs1 = 1'b0;
        fwd_alu_out_rs2 = 1'b0;
        //forwarding alu_out to rs1
        if ((rs1ID == instr_D[11:7]) && //forward in EX
            ctrl_signals_D.rfWrite &&
            useRs1Var && ~notReg0Rs1 && valid_alu_out) begin
                fwd_alu_out_rs1 = 1'b1;
            end
        //forwarding alu_out to rs2
        if (((rs2ID == instr_D[11:7]) && //forward in EX
            ctrl_signals_D.rfWrite &&
            useRs2Var && ~notReg0Rs2 && valid_alu_out) ||
            (syscallFwd(instr_D, ctrl_signals_D) && valid_alu_out)) begin //syscall forward
                fwd_alu_out_rs2 = 1'b1;
            end

        /*****  FORWARDING ALU_OUT FROM MEM1    *****/
        fwd_alu_out_rs1_E = 1'b0;
        fwd_alu_out_rs2_E = 1'b0;
        //forwarding alu_out to rs1
        if ((rs1ID == instr_DE[11:7]) && //forward in MEM1
            ctrl_signals_DE.rfWrite &&
            useRs1Var && ~notReg0Rs1 && valid_alu_out_E) begin
                fwd_alu_out_rs1_E = 1'b1;
            end
        //forwarding alu_out to rs2
        if (((rs2ID == instr_DE[11:7]) && //forward in MEM1
            ctrl_signals_DE.rfWrite &&
            useRs2Var && ~notReg0Rs2 && valid_alu_out_E) ||
            (syscallFwd(instr_DE, ctrl_signals_DE) && valid_alu_out_E)) begin //syscall forward
                fwd_alu_out_rs2_E = 1'b1;
            end

        /*****  FORWARDING ALU_OUT FROM MEM2    *****/
        fwd_alu_out_rs1_M1 = 1'b0;
        fwd_alu_out_rs2_M1 = 1'b0;
        //forwarding alu_out to rs1
        if ((rs1ID == instr_DEM1[11:7]) && //forward in MEM2
            ctrl_signals_DEM1.rfWrite &&
            useRs1Var && ~notReg0Rs1 && valid_alu_out_EM1) begin
                fwd_alu_out_rs1_M1 = 1'b1;
            end
        //forwarding alu_out to rs2
        if (((rs2ID == instr_DEM1[11:7]) && //forward in MEM2
            ctrl_signals_DEM1.rfWrite &&
            useRs2Var && ~notReg0Rs2 && valid_alu_out_EM1) ||
            (syscallFwd(instr_DEM1, ctrl_signals_DEM1) && valid_alu_out_EM1)) begin //syscall fwd
                fwd_alu_out_rs2_M1 = 1'b1;
            end

        /*****  FORWARDING MEM_OUT FROM MEM2    *****/
        //ONLY on a dcache_read_hit are we allowed to do this
        fwd_mem_out_rs1_M1 = 1'b0;
        fwd_mem_out_rs2_M1 = 1'b0;
        //forwarding alu_out to rs1
        if ((rs1ID == instr_DEM1[11:7]) && //forward in MEM2
            ctrl_signals_DEM1.rfWrite &&
            useRs1Var && ~notReg0Rs1 && valid_mem_out_M1 && dcache_read_hit) begin
                fwd_mem_out_rs1_M1 = 1'b1;
            end
        //forwarding alu_out to rs2
        if (((rs2ID == instr_DEM1[11:7]) && //forward in MEM2
            ctrl_signals_DEM1.rfWrite &&
            useRs2Var && ~notReg0Rs2 && valid_mem_out_M1 && dcache_read_hit) ||
            (syscallFwd(instr_DEM1, ctrl_signals_DEM1) && valid_mem_out_M1 && dcache_read_hit)) begin //syscall fwd
                fwd_mem_out_rs2_M1 = 1'b1;
            end

        /*****  FORWARDING ALU_OUT FROM WB    *****/
        fwd_alu_out_rs1_M2 = 1'b0;
        fwd_alu_out_rs2_M2 = 1'b0;
        //forwarding alu_out to rs1
        if ((rs1ID == instr_DEM1M2[11:7]) && //forward in MEM2
            ctrl_signals_DEM1M2.rfWrite &&
            useRs1Var && ~notReg0Rs1 && valid_alu_out_EM1M2) begin
                fwd_alu_out_rs1_M2 = 1'b1;
            end
        //forwarding alu_out to rs2
        if (((rs2ID == instr_DEM1M2[11:7]) && //forward in MEM2
            ctrl_signals_DEM1M2.rfWrite &&
            useRs2Var && ~notReg0Rs2 && valid_alu_out_EM1M2) ||
            (syscallFwd(instr_DEM1M2, ctrl_signals_DEM1M2) && valid_alu_out_EM1M2)) begin //syscall fwd
                fwd_alu_out_rs2_M2 = 1'b1;
            end

        /*****  FORWARDING MEM_OUT FROM WB    *****/
        fwd_mem_out_rs1_M2 = 1'b0;
        fwd_mem_out_rs2_M2 = 1'b0;
        //forwarding mem_out to rs1
        if ((rs1ID == instr_DEM1M2[11:7]) && //forward in WB
            ctrl_signals_DEM1M2.rfWrite &&
            useRs1Var && ~notReg0Rs1 && valid_mem_out_M2) begin
                fwd_mem_out_rs1_M2 = 1'b1;
            end
        //forwarding mem_out to rs2
        if (((rs2ID == instr_DEM1M2[11:7]) && //forward in WB
            ctrl_signals_DEM1M2.rfWrite &&
            useRs2Var && ~notReg0Rs2 && valid_mem_out_M2) ||
            (syscallFwd(instr_DEM1M2, ctrl_signals_DEM1M2) && valid_mem_out_M2)) begin //syscall fwd
                fwd_mem_out_rs2_M2 = 1'b1;
            end

        //loadAdd dependencies detection
        //This is only case that will cause stall
        if (((rs1ID == instr_D[11:7]) &&
            ctrl_signals_D.rfWrite &&
            ctrl_signals_D.memRead &&
            useRs1Var && ~notReg0Rs1) || //load in EX
            
            ((rs1ID == instr_DE[11:7]) &&
            ctrl_signals_DE.rfWrite &&
            ctrl_signals_DE.memRead &&
            useRs1Var && ~notReg0Rs1) || //load in MEM1

            ((rs1ID == instr_DEM1[11:7]) &&
            ctrl_signals_DEM1.rfWrite &&
            ctrl_signals_DEM1.memRead &&
            useRs1Var && ~notReg0Rs1 && ~dcache_read_hit) || //load in MEM2

            ((rs2ID == instr_D[11:7]) &&
            ctrl_signals_D.rfWrite &&
            ctrl_signals_D.memRead &&
            useRs2Var && ~notReg0Rs2) || //load in EX

            ((rs2ID == instr_DE[11:7]) &&
            ctrl_signals_DE.rfWrite &&
            ctrl_signals_DE.memRead &&
            useRs2Var && ~notReg0Rs2) || //load in MEM1

            ((rs2ID == instr_DEM1[11:7]) &&
            ctrl_signals_DEM1.rfWrite &&
            ctrl_signals_DEM1.memRead &&
            useRs2Var && ~notReg0Rs2 && ~dcache_read_hit)) //load in MEM2

            loadAdd = 1'b1;
        else loadAdd = 1'b0;

    end

endmodule : forwardDetection



/**
* syscall implementation
* if syscall detected in decode stage, either wait for forwarding
* or stall if there are addLoad dependencies
* if x10 = 10 (ecall condition met) inject bubbles for 3 cycles
* otherwise treat ecall as noOp
**/
module syscallDetect(
    input logic rst_l, clk,
    input ctrl_signals_t ctrl_signals, ctrl_signals_DEM1M2,
    input logic instr_mem_excpt, data_mem_excpt,
    input logic [31:0] rs2_data_DEM1M2,
    output logic halted);

    import RISCV_ISA::*;
    import RISCV_ABI::ECALL_ARG_HALT;

    logic checkSyscall, startCount;
    logic [2:0] syscallCount;
    logic syscall_halt, exception_halt;
    logic [31:0] a0_value;

    //only check the ECALL condition (a0 value) in WB
    assign a0_value         = rs2_data_DEM1M2;
    assign syscall_halt     = (a0_value == ECALL_ARG_HALT) && 
        ctrl_signals_DEM1M2.syscall;
    assign exception_halt   = instr_mem_excpt | data_mem_excpt |
        ctrl_signals_DEM1M2.illegal_instr;
    assign halted = rst_l & (syscall_halt | exception_halt);

endmodule : syscallDetect


/**
 * The arithmetic-logic unit (ALU) for the RISC-V processor.
 *
 * The ALU handles executing the current instruction, producing the
 * appropriate output based on the ALU operation specified to it by the
 * decoder.
 *
 * Inputs:
 *  - alu_src1      The first operand to the ALU.
 *  - alu_src2      The second operand to the ALU.
 *  - alu_op        The ALU operation to perform.
 *  - ctrl_signals  btype handling.
 *
 * Outputs:
 *  - alu_out       The result of the ALU operation on the two sources.
 *  - bcond_out     branch condition boolean.
 **/
//rewrote logic to shorten previous crit path
//instead of cascading muxes + shifting (maybe 3 barrel shifter)
//we operate first, then use single mux
module riscv_alu
    (input  logic [31:0]        alu_src1,
     input  logic [31:0]        alu_src2,
     input  alu_op_t            alu_op,
     input  ctrl_signals_t      ctrl_signals,
     output logic [31:0]        alu_out,
     output logic              bcond_out);

    import RISCV_ISA::*;

    //add/sub signals
    logic [31:0] sum;
    logic sub_sel;

    //add/sub logic
    assign sub_sel = (alu_op == ALU_SUB);
    adder #($bits(alu_src1)) ALU_Adder
        (.A(alu_src1), .B(sub_sel ? ~alu_src2 : alu_src2),
         .cin (sub_sel), .sum (sum), .cout());

    //shift signals
    logic [4:0]  shamt;
    logic [31:0] shift_res;

    //shift amt is always src2
    assign shamt = alu_src2[4:0];
    //shifting logic
    always_comb begin
        unique case (alu_op)
            ALU_SLL: shift_res = alu_src1 << shamt;
            ALU_SRL: shift_res = alu_src1 >> shamt;
            ALU_SRA: shift_res = $signed(alu_src1) >>> shamt;
            default: shift_res = 32'b0;
        endcase
    end

    //boolean logic
    logic [31:0] logic_res;
    always_comb begin
        unique case (alu_op)
            ALU_XOR: logic_res = alu_src1 ^ alu_src2;
            ALU_OR:  logic_res = alu_src1 | alu_src2;
            ALU_AND: logic_res = alu_src1 & alu_src2;
            default: logic_res = 32'b0;
        endcase
    end

    //comparison logic
    logic [31:0] cmp_res;
    always_comb begin
        unique case (alu_op)
            ALU_SLT:  cmp_res = {31'b0, ($signed(alu_src1) < $signed(alu_src2))};
            ALU_SLTU: cmp_res = {31'b0, (alu_src1 < alu_src2)};
            default:  cmp_res = 32'b0;
        endcase
    end

    //then select based on alu_op
    always_comb begin
        unique case (alu_op)
            ALU_ADD:  alu_out = sum;
            ALU_SUB:  alu_out = sum;

            ALU_SLL,
            ALU_SRL,
            ALU_SRA:  alu_out = shift_res;

            ALU_XOR,
            ALU_OR,
            ALU_AND:  alu_out = logic_res;

            ALU_SLT,
            ALU_SLTU: alu_out = cmp_res;

            default:  alu_out = 'bx;
        endcase
    end

    //branch condition logic (separate comparison)
    logic bcond;
    always_comb begin
        unique case (ctrl_signals.btype)
            FUNCT3_BEQ:  bcond = (alu_src1 == alu_src2);
            FUNCT3_BNE:  bcond = (alu_src1 != alu_src2);
            FUNCT3_BLT:  bcond = ($signed(alu_src1) <  $signed(alu_src2));
            FUNCT3_BGE:  bcond = ($signed(alu_src1) >= $signed(alu_src2));
            FUNCT3_BLTU: bcond = (alu_src1 <  alu_src2);
            FUNCT3_BGEU: bcond = (alu_src1 >= alu_src2);
            default:     bcond = 1'b0;
        endcase
    end
    //bcond_out only asserted when branch is taken (JAL, JALR not counted)
    always_comb begin
        if (ctrl_signals.pc_source == PC_cond)
            bcond_out = bcond;
        else
            bcond_out = 1'b0;
    end

endmodule : riscv_alu

/**
* Byte mask logic in fwd path from MEM to EX
* This shortens previous crit path and allows
* forwarding from beginning of WB stage
**/
module byteMask(
    input  logic [31:0]        data_load,
    input  ctrl_signals_t      ctrl_signals,
    input  logic [31:0]        alu_out,
    output logic [31:0]        rd_data
);

    /********** Load/Store instruction handling **********/

    logic [1:0] byte_off;
    assign byte_off = alu_out[1:0];

    logic [31:0] shifted;
    //shift first
    always_comb begin
        unique case (byte_off)
            2'b00: shifted = data_load;
            2'b01: shifted = {8'b0, data_load[31:8]};
            2'b10: shifted = {16'b0, data_load[31:16]};
            2'b11: shifted = {24'b0, data_load[31:24]};
            default: shifted = data_load;
        endcase
    end

    logic [31:0] l_byte, l_byte_u, l_half, l_half_u;

    //then case on ldst type
    always_comb begin
        l_byte   = {{24{shifted[7]}}, shifted[7:0]};
        l_byte_u = {24'b0, shifted[7:0]};
        l_half   = {{16{shifted[15]}}, shifted[15:0]};
        l_half_u = {16'b0, shifted[15:0]};
    end
    always_comb begin
        unique case (ctrl_signals.ldst_mode)
            LDST_W:  rd_data = data_load;
            LDST_H:  rd_data = l_half;
            LDST_HU: rd_data = l_half_u;
            LDST_B:  rd_data = l_byte;
            LDST_BU: rd_data = l_byte_u;
            default: rd_data = 'bx;
        endcase
    end
endmodule : byteMask