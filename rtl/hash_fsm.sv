/*
 * Module Name: hash_fsm
 * Author(s): Ailiya Jafri, Kiet Le
 * Description:
 * Control path orchestrator for Ascon-Hash256, Ascon-XOF128, and Ascon-CXOF128.
 * Interfaces with the Ascon Core and the Padder unit to absorb messages and
 * squeeze digests, supporting continuous squeeze mode via the abort_i signal.
 */

`timescale 1ns / 1ps
import ascon_pkg::*;

module hash_fsm (
    input  logic           clk,
    input  logic           rst,

    // -----------------------------------------------------------------------
    // Hash FSM Control I/O
    // -----------------------------------------------------------------------
    input  ascon_mode_t    mode_i,
    input  logic [31:0]    xof_len_i,     // 0 = Infinite/Continuous Mode, else specific byte length
    input  logic           start_i,
    input  logic           abort_i,       // Pulse high to terminate continuous squeezing
    output logic           busy_o,
    output logic           done_o,

    // -----------------------------------------------------------------------
    // Ascon Core Control I/O
    // -----------------------------------------------------------------------
    input  logic           ascon_ready_i,
    output logic           start_perm_o,
    output logic           round_config_o, // e.g., 0 for p^12, 1 for p^8
    output logic [2:0]     word_sel_o,
    output ascon_word_t    data_o,         // Used to write the pre-computed Hash IVs
    output logic           write_en_o,
    output logic [1:0]     core_in_data_sel_o,
    output logic [1:0]     xor_sel_o,

    // -----------------------------------------------------------------------
    // Padded AXI4-Stream Slave (Data coming FROM the Padder)
    // -----------------------------------------------------------------------
    input  axi_tuser_t     padded_tuser_i,
    input  logic           padded_tlast_i,
    input  logic           padded_tvalid_i,
    output logic           padded_tready_o,

    // -----------------------------------------------------------------------
    // AXI4-Stream Master (Data going OUT)
    // -----------------------------------------------------------------------
    output logic [7:0]     m_axis_tkeep_o,
    output axi_tuser_t     m_axis_tuser_o,
    output logic           m_axis_tlast_o,
    output logic           m_axis_tvalid_o,
    input  logic           m_axis_tready_i
);

    // =======================================================================
    // FSM State Declarations & Logic
    // =======================================================================
    typedef enum {
        STATE_IDLE,
        STATE_INIT,
        STATE_PERM,
        STATE_ABSORB,
        STATE_SQUEEZE
    } state_t;
    state_t state, next_state;

    logic [2:0] word_cnt, next_word_cnt;
    logic       is_final_perm, next_is_final_perm;

    localparam ascon_word_t ASCON_HASH_IV_WORD0 = 64'h00000080100cc0002;
    localparam ascon_word_t ASCON_XOF_IV_WORD0  = 64'h00000080100c40002;

    // (State machine logic goes here)

    // =======================================================================
    // CONTROL FSM
    // =======================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= STATE_IDLE;
            word_cnt      <= 3'd0;
            is_final_perm <= 1'b0;
        end else begin
            state         <= next_state;
            word_cnt      <= next_word_cnt;
            is_final_perm <= next_is_final_perm;
        end
    end

    // =======================================================================
    // NEXT STATE DECODER
    // =======================================================================
    always_comb begin
        next_state         = state;
        next_word_cnt      = word_cnt;
        next_is_final_perm = is_final_perm;

        case (state)
            STATE_IDLE: begin
                if (start_i) next_state = STATE_INIT;
            end

            STATE_INIT: begin
                if (word_cnt == 3'd4) begin
                    next_word_cnt = 3'd0;
                    next_state    = STATE_PERM;
                end else begin
                    next_word_cnt = word_cnt + 3'd1;
                end
            end

            STATE_PERM: begin
                if (ascon_ready_i) begin
                    if (is_final_perm) begin
                        next_state    = STATE_SQUEEZE;
                        next_word_cnt = 3'd0;
                    end else begin
                        next_state    = STATE_ABSORB;
                    end
                end
            end

            STATE_ABSORB: begin
                if (padded_tvalid_i && padded_tready_o) begin
                    next_state = STATE_PERM;
                    if (padded_tlast_i) next_is_final_perm = 1'b1;
                end
            end

            STATE_SQUEEZE: begin
                if (m_axis_tready_i && m_axis_tvalid_o) begin
                    // Condition for Hash256 (4 words) or XOF abort
                    if (word_cnt == 3'd3 || abort_i) begin
                        next_state = STATE_DONE;
                    end else begin
                        next_word_cnt = word_cnt + 3'd1;
                        next_state    = STATE_PERM;
                    end
                end
            end

            STATE_DONE: begin
                next_state = STATE_IDLE;
            end

            default: next_state = STATE_IDLE;
        endcase
    end

    // =======================================================================
    // OUTPUT DECODER
    // =======================================================================
    always_comb begin
        // Default values
        busy_o             = 1'b1;
        done_o             = 1'b0;
        start_perm_o       = 1'b0;
        round_config_o     = 1'b0;
        write_en_o         = 1'b0;
        word_sel_o         = word_cnt;
        core_in_data_sel_o = 2'b00;
        xor_sel_o          = 2'b00;
        padded_tready_o    = 1'b0;
        m_axis_tvalid_o    = 1'b0;
        m_axis_tlast_o     = 1'b0;
        m_axis_tkeep_o     = 8'hFF;
        data_o             = 64'b0;

        case (state)
            STATE_IDLE: begin
                busy_o = 1'b0;
            end

            STATE_INIT: begin
                write_en_o = 1'b1;
            if (word_cnt == 3'd0) begin
                data_o = (mode_i == ASCON_XOF) ? ASCON_XOF_IV_WORD0 : ASCON_HASH_IV_WORD0;
            end else begin
                data_o = 64'b0; // Words 1, 2, 3, and 4 are initialized to 0
            end
        end

            STATE_PERM: begin
                // Trigger permutation if core is idle
                if (ascon_ready_i) start_perm_o = 1'b1;
            end

            STATE_ABSORB: begin
                padded_tready_o = ascon_ready_i;
                xor_sel_o       = 2'b01; // Tells core to XOR padded_tdata into state
            end

            STATE_SQUEEZE: begin
                m_axis_tvalid_o = 1'b1;
                if (word_cnt == 3'd3 || abort_i) begin
                    m_axis_tlast_o = 1'b1;
                end
            end

            STATE_DONE: begin
                done_o = 1'b1;
            end
        endcase
    end

endmodule
