`include "internal_defines.vh"

module fifo # (
    // I found a paper by Sutherland & Mills (2013) about synthesisable
    // generic types and it's pretty cool
    parameter WIDTH = 64,
    parameter MAX_ELEMENTS = 2,
    parameter MAX_ENQ      = 1,
    parameter MAX_DEQ      = 1
) (
    input logic clk, rst_l,
    input logic peek_only,  
    input logic flush, 
    
    input logic [ MAX_ENQ - 1 : 0 ][WIDTH-1:0]    enq_data,
    input logic [ $clog2(MAX_ENQ + 1) - 1 : 0] num_enq,
    input logic [ $clog2(MAX_DEQ + 1) - 1 : 0] num_deq,

    output logic [ MAX_DEQ - 1 : 0 ][WIDTH-1:0]             deq_data,
    output logic [ $clog2(MAX_ENQ + 1) - 1 : 0]      num_suc_enq,
    output logic [ $clog2(MAX_DEQ + 1) - 1 : 0]      num_suc_deq,
    output logic [ $clog2(MAX_ELEMENTS + 1) - 1 : 0] num_q_elem,
    output logic empty
);

    typedef struct packed {
        logic [MAX_ELEMENTS - 1 : 0 ] [WIDTH-1:0]                data;
        logic [ $clog2(MAX_ELEMENTS + 1) - 1 : 0 ] head_ptr, tail_ptr, num_elems;
    } queue_state_t;
    
    queue_state_t curr_queue_state, new_queue_state; 

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            curr_queue_state <= 'b0; 
        end else if (flush) begin
            curr_queue_state <= 'b0; 
        end else begin
            curr_queue_state <= new_queue_state; 
        end
    end
    
    // variables owned by each thread for local counting of elements
    logic [ $clog2(MAX_ELEMENTS + 1) - 1 : 0] new_head, new_tail;

    always_comb begin
        deq_data = '0; 
        // DEQ from the head of the current queue
        if (curr_queue_state.num_elems < num_deq) 
            num_suc_deq = curr_queue_state.num_elems; 
        else 
            num_suc_deq = num_deq; 

        new_head = curr_queue_state.head_ptr; 
        for (int i = 0; i < num_suc_deq; i++) begin
            deq_data[i] = curr_queue_state.data[new_head];
            new_head ++;
            if (new_head >= MAX_ELEMENTS) begin
                new_head = '0; 
            end 
        end
        if (peek_only) begin
            new_head    = curr_queue_state.head_ptr;
            num_suc_deq = '0;
        end 

        empty = deq_data;
    end

    always_comb begin
        new_queue_state.data = curr_queue_state.data; 
        // ENQ from the tail of the current queue
        if (MAX_ELEMENTS == curr_queue_state.num_elems) 
            num_suc_enq = '0; // MAX_ELEMENTS - curr_queue_state.num_elems; 
        else 
            num_suc_enq = num_enq; 

        new_tail = curr_queue_state.tail_ptr; 
        for (int i = 0; i < num_suc_enq; i++) begin
            new_queue_state.data[new_tail] = enq_data[i];
            new_tail ++; 
            if (new_tail >= MAX_ELEMENTS) begin
                new_tail = '0; 
            end
        end
    end

    assign new_queue_state.num_elems = curr_queue_state.num_elems - num_suc_deq + num_suc_enq; 
    assign new_queue_state.tail_ptr  = new_tail;
    assign new_queue_state.head_ptr  = new_head;
    assign num_q_elem                = curr_queue_state.num_elems;  
endmodule: fifo
