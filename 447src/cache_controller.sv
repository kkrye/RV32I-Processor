/**
 * A cache controller module for handling memory requests.
 *
 * This module implements a cache controller to interface between a core, a 
 * pipelined one-stage cache and a memory.
 *
 * Parameters:
 *  - INDEX_BITS            Number of bits in the address that form the set index.
 *  - BLOCK_OFFSET_BITS     Number of bits in the address that determine the block offset.
 *  - BLOCK_SIZE            Number of words per block (derived from BLOCK_OFFSET_BITS).
 *  - WAYS                  The associativity of the cache (number of ways per set).
 *  - WORD_SIZE             The size of a single word in bits.
 *  - ADDRESS_SIZE          The size of the memory address in bits.
 *  - POLICY                The cache eviction policy switch. (0 -> DIRECT, 1 -> LRU, 2 -> MRU, etc.)      
 *
 * Inputs:
 *  - clk                   The clock.
 *  - rst_l                 Asynchronous active-low reset signal.
 * 
 * Core to cache (input):
 *  - core_req_we           Enables a cache write on the address specified.
 *  - core_req_re           Enables a cache read on the address specified.
 *  - core_req_addr         The requested memory address
 *  - core_req_store_mask   A byte-wise mask of the store data to store
 *  - core_req_store_data   The data to be stored, if core_req_we is asserted
 *  - core_req_cancel       Invalidates an in-flight request 
 *  - core_req_stall_mem    Holds the current data output constant while stall is asserted
 *
 * Cache to core (output):
 *  - core_rsp_addr         The address corresponding to the returned data
 *  - core_rsp_data         The data responese to core read request
 *  - core_rsp_data_valid   Indicates returned data is valid
 *  - core_rsp_ready        Controller is available to receive a new request
 *  - core_rsp_excpt        Forwarded mem_excpt signal to core
 * 
 * Memory to cache (input)
 *  - mem_rsp_data          The data responese to controller read request
 *  - mem_rsp_valid         Indicates returned data is valid
 *  - mem_rsp_addr          The address corresponding to the returned data
 *  - mem_rsp_ready         Memory is available to receive a new request
 *  - mem_rsp_excpt         Memory exception signal
 * 
 * Cache to memory (output)
 *  - mem_req_data_load_en  Enables a memory read on the address specified.
 *  - mem_req_store_mask    Enables a memory write write on the address and bytes specified
 *  - mem_req_addr          The controller requested memory address
 *  - mem_req_store_data    The data to be stored, if mem_req_store_mask is nonzero
 *
 *  Data collection (output)
 *  - is_eviction           Asserted on a cache eviction
 *  - read_hit              Asserted on a cache hit
 *  - read_miss             Asserted on a cache miss
 *
 *
 * Authors:
 *     - 2026: Feya Epel and Elisa Mayer
 */



module cache_controller #(    
    // parameters for the cache that will be contained within the controller
    parameter INDEX_BITS        = 4,
    parameter BLOCK_OFFSET_BITS = 2,
    parameter BLOCK_SIZE        = 2 ** BLOCK_OFFSET_BITS,
    parameter WAYS = 4,

    parameter WORD_SIZE    = 32,
    parameter ADDRESS_SIZE = 30,

    parameter POLICY = -1
) (
    input logic clk, rst_l,
    
    /* Core facing interface */
    input logic                                         core_req_we,
    input logic                                         core_req_re,
    input logic [ADDRESS_SIZE - 1 : 0]                  core_req_addr,
    input logic [3:0]                                   core_req_store_mask,
    input logic [WORD_SIZE - 1 : 0]                     core_req_store_data, 
    input logic                                         core_req_cancel,
    input logic                                         core_req_stall_mem,

    output logic [ADDRESS_SIZE - 1 : 0 ]                core_rsp_addr,
    output logic [WORD_SIZE - 1 : 0 ]                   core_rsp_data,
    output logic                                        core_rsp_data_valid,
    output logic                                        core_rsp_ready, 
    output logic                                        core_rsp_excpt, 

    /* Memory facing controls & data */
    input logic [BLOCK_SIZE - 1 : 0][WORD_SIZE - 1 : 0] mem_rsp_data,
    input logic                                         mem_rsp_valid,
    input logic [ADDRESS_SIZE - 1 : 0 ]                 mem_rsp_addr,
    input logic                                         mem_rsp_ready, 
    input logic                                         mem_rsp_excpt,

    output logic                                        mem_req_data_load_en,
    output logic [3:0]                  mem_req_store_mask,
    output logic [ADDRESS_SIZE - 1 : 0 ]                mem_req_addr,
    output logic [WORD_SIZE - 1 : 0 ]                   mem_req_store_data,

    /* For performance counters */
    output logic                                        is_eviction,
    output logic                                        read_hit,
    output logic                                        read_miss
);

    enum logic [1:0] {IDLE, WAIT_FOR_RSP, CACHE_RSP, WAIT_FOR_BUS} state, next_state;
    logic [31:0]        c_read_d;
    logic [29:0]        address;
    logic               enable;
    logic               rd_en;
    logic               wr_en;
    logic               ud_en;
    logic               flush;
    logic               cancel;
    logic [3:0]         write_data_valid;
    logic [3:0][31:0]   write_data;
    logic [3:0]         update_data_valid;
    logic [3:0][31:0]   update_data;
    logic [31:0]        read_data;
    logic [29:0]        req_addr;
    logic               fifo_enable;
    logic [62:0]        fifo_data;
    logic               stall;
    logic [3:0]         registered_store_mask;
    logic [31:0]        registered_store_data;
    logic [29:0]        registered_addr;
    logic               register_store_data;


    cache
        #(.INDEX_BITS(INDEX_BITS),
        .BLOCK_OFFSET_BITS(BLOCK_OFFSET_BITS),
        .WAYS(WAYS),
        .WORD_SIZE(WORD_SIZE),
        .ADDRESS_SIZE(ADDRESS_SIZE),
        .POLICY(POLICY)
        )
        craching_out (
        .clk, .rst_l,
        .address,
        .rd_en,
        .wr_en,
        .ud_en,
        .flush,
        .cancel, 
        .stall,
        .user_write_data_valid(write_data_valid),
        .user_write_data(write_data),

        .user_update_data_valid(update_data_valid),
        .user_update_data(update_data),

        .read_data,
        .user_read_hit(read_hit),
        .user_read_miss(read_miss),
        .user_is_eviction(is_eviction)
        );


    always_comb begin        

        /* Core response variables */
        core_rsp_ready                      = 1'b1;
        core_rsp_excpt                      = mem_rsp_excpt;

        /* Mem request variables */
        mem_req_data_load_en                = 1'b0;
        mem_req_store_mask                  = 'b0;
        mem_req_addr                        = 1'b0;
        mem_req_store_data                  = core_req_store_data;

        /* Cache request variables */
        enable                              = 'b0;
        address                             = {core_req_addr[29:2], 2'b0}; // Always four word aligned on a store/update
        write_data                          = 'b0;
        write_data_valid                    = 'b0;
        update_data                          = 'b0;
        update_data_valid                    = 'b0;
        flush                               = 'b0;
        rd_en                               = 1'b0; // Read enable 
        wr_en                               = 1'b0; // On a store, assert write enable
        ud_en                               = 1'b0; // On a read miss, assert update enable
        cancel                              = 1'b0;

        fifo_data                           = 'b0;
        fifo_enable                         = 1'b0;
        stall                               = 1'b0;
        register_store_data                 = 1'b0;
        unique case (state)
            IDLE: begin
                next_state = IDLE;
                mem_req_addr = core_req_addr;
                /* Handle new memory request */
                if (core_req_re) begin
                    enable      = 1'b1; // Store address in case we need it
                    next_state  = CACHE_RSP;
                    rd_en       = 1'b1;
                    address     = core_req_addr;
                end
                else if (core_req_we) begin
                    mem_req_store_mask = core_req_store_mask;
                    if (mem_rsp_ready) begin
                        if (core_req_store_mask == 4'hf) begin
                            write_data[core_req_addr[1:0]] = core_req_store_data;
                            write_data_valid[core_req_addr[1:0]] = 1'b1;
                            wr_en = 1'b1;
                        end
                        else begin
                            flush = 1'b1;
                        end
                    end else begin
                        next_state = WAIT_FOR_BUS;
                        register_store_data = 1'b1;
                    end
                end
                if (core_req_cancel) begin
                    next_state  = IDLE;
                    mem_req_store_mask = 'b0;
                end
            end
            WAIT_FOR_BUS: begin
                $display($time, , "You reached the WAIT_FOR_BUS state in the cache controller FSM. If this isn't working how you expected, please contact course staff.");
                next_state = WAIT_FOR_BUS;
                core_rsp_ready = 1'b0;
                mem_req_store_mask = registered_store_mask;
                mem_req_store_data = registered_store_data;
                mem_req_addr = registered_addr;
                if (mem_rsp_ready) begin
                    next_state = IDLE;
                    address = registered_addr;
                    if (registered_store_mask == 4'hf) begin
                        /* Cache logic */
                        write_data[registered_addr[1:0]] = registered_store_data;
                        write_data_valid[registered_addr[1:0]] = 1'b1;
                        wr_en = 1'b1;
                    end
                    else begin
                        flush = 1'b1;
                    end
                end 
            end
            CACHE_RSP: begin
                next_state = IDLE;
                
                mem_req_addr = core_req_addr;
                
                if (read_hit) begin
                    fifo_enable = 1'b1;
                    fifo_data = {1'b1, read_data, req_addr};
                    
                    if (core_req_re) begin
                        enable      = 1'b1; // Store address in case we need it
                        next_state  = CACHE_RSP;
                        rd_en       = 1'b1;
                        address     = core_req_addr;
                    end
                    else if (core_req_we) begin
                        mem_req_store_mask = core_req_store_mask;
                        if (mem_rsp_ready) begin
                            if (core_req_store_mask == 4'hf) begin
                                write_data[core_req_addr[1:0]] = core_req_store_data;
                                write_data_valid[core_req_addr[1:0]] = 1'b1;
                                wr_en = 1'b1;
                            end
                            else begin
                                flush = 1'b1;
                            end
                        end else begin
                            next_state = WAIT_FOR_BUS;
                            register_store_data = 1'b1;
                        end
                    end
                end
                else if (read_miss) begin
                    core_rsp_ready = 1'b0;
                    mem_req_data_load_en = 1'b1;
                    mem_req_addr = {req_addr[29:2], 2'b0};
                    if (mem_rsp_ready) begin
                        next_state = WAIT_FOR_RSP;
                    end else begin
                        stall      = 1'b1; 
                        next_state = CACHE_RSP; 
                    end
                end

                if (core_req_cancel) begin
                    next_state  = IDLE;
                    cancel = 1'b1;
                    mem_req_store_mask = 'b0;
                end 
            end
            WAIT_FOR_BUS: begin
                $display($time, , 
                    "You reached the WAIT_FOR_BUS state in the cache controller FSM. If this isn't working how you expected, please contact course staff.");
                next_state = WAIT_FOR_BUS;
                core_rsp_ready = 1'b0;
                mem_req_store_mask = registered_store_mask;
                mem_req_store_data = registered_store_data;
                mem_req_addr = registered_addr;
                if (mem_rsp_ready) begin
                    next_state = IDLE;
                    address = registered_addr;
                    if (registered_store_mask == 4'hf) begin
                        /* Cache logic */
                        write_data[registered_addr[1:0]] = registered_store_data;
                        write_data_valid[registered_addr[1:0]] = 1'b1;
                        wr_en = 1'b1;
                    end
                    else begin
                        flush = 1'b1;
                    end
                end
            end
            WAIT_FOR_RSP: begin
                core_rsp_ready = 1'b0;
                mem_req_addr = core_req_addr;
                next_state  = WAIT_FOR_RSP;
                
                if (mem_rsp_valid & (mem_rsp_addr[29:2] == req_addr[29:2])) begin
                    core_rsp_ready = 1'b1;
                    ud_en = 1'b1;
                    update_data_valid = 4'b1111;
                    update_data = mem_rsp_data;
                    address = req_addr;

                    fifo_enable = 1'b1;
                    fifo_data = {1'b1, mem_rsp_data[req_addr[1:0]], req_addr};

                    next_state = IDLE; 
                    if (core_req_re) begin
                        enable      = 1'b1; // Store address in case we need it
                        next_state  = CACHE_RSP;
                        address     = core_req_addr;
                        rd_en       = 1'b1;
                    end
                    else if (core_req_we) begin
                        next_state = IDLE;
                        mem_req_store_mask = core_req_store_mask;
                        if (mem_rsp_ready) begin
                           if (core_req_store_mask == 4'hf) begin
                                write_data[core_req_addr[1:0]] = core_req_store_data;
                                write_data_valid[core_req_addr[1:0]] = 1'b1;
                                address = core_req_addr;
                                wr_en = 1'b1;
                            end
                            else begin
                                flush = 1'b1;
                            end
                        end
                        else begin
                            next_state = WAIT_FOR_BUS;
                            register_store_data = 1'b1;
                        end
                    end
                end
                if (core_req_cancel) begin
                    next_state  = IDLE;
                    mem_req_store_mask = 'b0; 
                    cancel      = 1'b1;
                end
            end
            default: begin
                next_state = IDLE;
            end
        endcase
    end

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            req_addr <= 'b0;
        end
        else if (enable) begin
            req_addr <= core_req_addr;
        end
    end

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            registered_store_mask <= 'b0;
            registered_store_data <= 'b0;
            registered_addr <= 'b0;
        end
        else if (register_store_data) begin
            registered_store_mask <= core_req_store_mask;
            registered_store_data <= core_req_store_data;
            registered_addr <= core_req_addr;
        end
    end

    fifo #(.WIDTH(63), .MAX_ELEMENTS(2)) feefifofum (
        .clk, .rst_l,
        .peek_only (core_req_stall_mem),  
        .enq_data(fifo_data),
        .num_enq(fifo_enable),
        .num_deq(1'b1),
        .flush(core_req_cancel),

        .deq_data({core_rsp_data_valid, core_rsp_data, core_rsp_addr}),
        .num_suc_enq(),
        .num_suc_deq(),
        .num_q_elem()
);

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l)
            state <= IDLE;
        else
            state <= next_state;
    end

endmodule: cache_controller
