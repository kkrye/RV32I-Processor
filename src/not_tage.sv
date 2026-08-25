`default_nettype none

module not_tage #(
    parameter LHT_SIZE   = 128,
    parameter PHT_SIZE   = 512,
    parameter HIST_BITS  = 8,
    parameter ADDR_BITS  = $clog2(LHT_SIZE)
)(
    input  logic        clk,
    input  logic        rst_l,
    
    input  logic [31:0] fetch_pc,
    output logic        pred_taken,

    input  logic        update_bp,
    input  logic [31:0] exec_pc,
    input  logic        was_taken,
    input  logic        mispredict
);

    logic [HIST_BITS-1:0] branch_history_table [LHT_SIZE];
    logic [1:0]           pattern_history_table [PHT_SIZE];

    logic [ADDR_BITS-1:0] f_bht_idx;
    logic [HIST_BITS-1:0] f_history;
    logic [$clog2(PHT_SIZE)-1:0] f_pht_idx;
    logic [ADDR_BITS-1:0] u_bht_idx;
    logic [HIST_BITS-1:0] u_history_old;
    logic [$clog2(PHT_SIZE)-1:0] u_pht_idx;


    assign f_bht_idx = fetch_pc[ADDR_BITS+1:2];
    assign f_history = branch_history_table[f_bht_idx];

    assign f_pht_idx = f_history ^ fetch_pc[$clog2(PHT_SIZE)+1:2];

    assign pred_taken = pattern_history_table[f_pht_idx][1];

    assign u_bht_idx = exec_pc[ADDR_BITS+1:2];
    
    assign u_history_old = branch_history_table[u_bht_idx];
    assign u_pht_idx = u_history_old ^ exec_pc[$clog2(PHT_SIZE)+1:2];

    always_ff @(posedge clk or negedge rst_l) begin
        if (!rst_l) begin
            for (int i = 0; i < LHT_SIZE; i++) branch_history_table[i] <= '0;
            for (int i = 0; i < PHT_SIZE; i++) pattern_history_table[i] <= 2'b11;
        end else if (update_bp) begin
            if (was_taken && pattern_history_table[u_pht_idx] != 2'b11)
                pattern_history_table[u_pht_idx] <= pattern_history_table[u_pht_idx] + 1'b1;
            else if (!was_taken && pattern_history_table[u_pht_idx] != 2'b00)
                pattern_history_table[u_pht_idx] <= pattern_history_table[u_pht_idx] - 1'b1;

            branch_history_table[u_bht_idx] <= {u_history_old[HIST_BITS-2:0], was_taken};
        end
    end

endmodule: not_tage
