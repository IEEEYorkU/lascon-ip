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
    typedef enum logic [6:0] {
        IDLE    = 7'b0000001,
        INIT    = 7'b0000010,
        ABSORB  = 7'b0000100,
        SQUEEZE = 7'b0001000
    } hash_state_e;

    hash_state_e State, NextState;

    // (State machine logic goes here)

    // =======================================================================
    // State register
    // =======================================================================
    always_ff @(posedge clk) begin
        if (rst)
            State <= IDLE;
        else
            State <= NextState;
    end

    // =======================================================================
    // Next state + outputs logic
    // =======================================================================
    always_comb begin
        // Defaults
        NextState = State;

        // =================================
        // State actions / transitions
        // =================================
        unique case (State)

            IDLE: begin
                busy_o = 1'b0;
                done_o = 1'b0;

                // wait for start
                if (start_i) begin
                    NextState = INIT;
                end
            end

            INIT: begin
                busy_o = 1'b1;

                // TODO:
                // NextState = ABSORB;
            end

            ABSORB: begin
                busy_o = 1'b1;

                // TODO:
                // NextState = SQUEEZE;
            end

            SQUEEZE: begin
                busy_o = 1'b1;

                // TODO:
                // NextState = IDLE;
            end

            default: begin
                NextState = IDLE;
            end
        endcase
    end

endmodule
