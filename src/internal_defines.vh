/**
 * internal_defines.vh
 *
 * RISC-V 32-bit Processor
 *
 * ECE 18-447
 * Carnegie Mellon University
 *
 * This contains the definitions of constants and types that are used by the
 * core of the RISC-V processor, such as control signals and ALU operations.
**/

/*----------------------------------------------------------------------------*
 *  You may edit this file and add or change any files in the src directory.  *
 *----------------------------------------------------------------------------*/

`ifndef INTERNAL_DEFINES_VH_
`define INTERNAL_DEFINES_VH_

// 2nd operand immediate mode
typedef enum logic [2:0] {
    IMM_I,
    IMM_S,
    IMM_SB,
    IMM_U,
    IMM_UJ,
    IMM_DC = 'bx            // Don't care value
} imm_mode_t;

// Constants that specify which operation the ALU should perform
typedef enum logic [3:0] {
    ALU_ADD,                // Addition operation
    ALU_SUB,                // Subtraction/Compare operation
    ALU_SLL,
    ALU_SRA,
    ALU_SRL,
    ALU_AND,
    ALU_OR,
    ALU_XOR,
    ALU_SLT,
    ALU_SLTU,
    ALU_DC = 'bx            // Don't care value
} alu_op_t;

// Load/store partial word mode
typedef enum logic [2:0] {
    LDST_W,
    LDST_H,
    LDST_HU,
    LDST_B,
    LDST_BU,
    LDST_DC = 'bx            // Don't care value
} ldst_mode_t;

// Next PC source
typedef enum logic [1:0] {
    PC_plus4,               // non-control flow
    PC_cond,                // Branch
    PC_uncond,              // JAL
    PC_indirect,            // indirect jump (JALR)
    PC_DC = 'bx		    
} pc_source_t;

/* The definition of the control signal structure, which contains all
 * microarchitectural control signals for controlling the MIPS datapath. */
typedef struct packed {
    logic useImm;           // 2nd ALU input from immediate else GPR port
    logic rfWrite;          // write GPR
    logic mem2RF;           // memory load result write to GPR
    logic pc2RF;            // PC+4 write to GPR (link)
    logic memRead;          // load instruction
    logic memWrite;         // store instruction
    imm_mode_t imm_mode;    // immediate mode applied
    alu_op_t alu_op;        // The ALU operation to perform
    ldst_mode_t ldst_mode;  // load/store partial word mode;
    pc_source_t pc_source;  // next PC source

    logic [2:0] btype;      // branch FUNCT3
    logic syscall;          // Indicates if the current instruction is a syscall
    logic illegal_instr;    // Indicates if the current instruction is illegal
    logic auipc;            // Indicates if the current instruction is an AUIPC
} ctrl_signals_t;

`endif /* INTERNAL_DEFINES_VH_ */
