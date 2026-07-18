/*
 * Module Name: lascon_core
 * Author(s):   Kiet Le, Arthur Sabadini
 * Description:
 * The central mathematical engine ("The Muscle") for the Lascon Cryptographic
 * Accelerator. This module encapsulates the 320-bit Ascon state and iteratively
 * executes the three permutation layers (Constant Addition, Substitution, and
 * Linear Diffusion) for a configurable number of rounds.
 *
 * Design Philosophy (Decoupled Data/Control):
 * This core is designed as a "dumb" slave permutation block. It possesses strictly
 * zero knowledge of higher-level cryptographic protocols, AXI4-Stream handshaking,
 * padding rules, or the difference between AEAD and Hashing. It relies entirely
 * on external protocol-specific orchestrators (FSMs) to feed it data, dictate
 * the number of rounds, and trigger the permutation.
 *
 * Implementation Details:
 * - Datapath Pipeline: Instantiates the three combinatorial layers of the Ascon
 * round logic (p_C -> p_S -> p_L).
 * - Control FSM: Built using a robust 4-process methodology (State Register,
 * Next State Logic, Output Decoder, Action Logic) to ensure glitch-free
 * synthesis and predictable timing.
 * - Memory Mapping: The 320-bit internal state is addressable as five distinct
 * 64-bit words via `word_sel_i`, allowing external controllers to overwrite
 * specific lanes (S_0 ... S_4) independently.
 * - Round Indexing: Implements a 0-indexed round counter (`rnd_cnt`). For the
 * 8-round permutation (p^8), the required mathematical suffix offset (+4) is
 * delegated to the `constant_addition_layer` module to extract the correct
 * round constants.
 *
 * Ref: NIST SP 800-232, Section 3
 */
`timescale 1ns / 1ps

import lascon_pkg::*;

module lascon_core #(
    parameter int LASCON_VARIANT = 0
)(
    input   logic           clk,
    input   logic           rst,

    // Permutation Control
    input   logic           start_perm_i,
    input   logic           round_config_i,

    // Read/Write Word Address
    input   logic [2:0]     word_sel_i,

    // Data I/O Control
    input   ascon_word_t    data_i,
    input   logic           write_en_i,


    // Data Output (according to word_sel_i)
    output  ascon_word_t    data_o,

    // Permutation Complete
    output  logic           ready_o
);

    // FSM States
    typedef enum logic [0:0] {
        STATE_IDLE,
        STATE_PERM
    } state_t;
    state_t state, next_state;

    rnd_t rnd_cnt;
    ascon_state_t state_array;

    // Permutation Layers Output
    ascon_state_t addition_state_array_o, substitution_state_array_o, diffusion_state_array_o;

    // Permutation Layers Instances
    constant_addition_layer const_add(
        .rnd_i(rnd_cnt),
        .state_array_i(state_array),
        .state_array_o(addition_state_array_o)
    );
    substitution_layer substitution(
        .state_array_i(addition_state_array_o),
        .state_array_o(substitution_state_array_o)
    );
    linear_diffusion_layer diffusion(
        .state_array_i(substitution_state_array_o),
        .state_array_o(diffusion_state_array_o)
    );

    // FSM Control Process 1: State Register (Sequential)
    // ----------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= STATE_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // FSM Control Process 2: Next State Decoder (Combinational)
    // ----------------------------------------------------------
    always_comb begin
        next_state = state;

        case(state)
            STATE_IDLE: begin
                if (start_perm_i) begin
                    next_state = STATE_PERM;
                end else begin
                    next_state = STATE_IDLE;
                end
            end

            STATE_PERM: begin
                if (rnd_cnt < 4'd11) begin
                    next_state = STATE_PERM;
                end else begin
                    next_state = STATE_IDLE;
                end
            end

            default: begin
                next_state = STATE_IDLE;
            end
        endcase
    end

    // FSM Control Process 3: Action Decoder (Combinational)
    // ----------------------------------------------------------
    assign ready_o = (state == STATE_IDLE);

    // FSM Control Process 4: Action Logic (Sequential)
    // ----------------------------------------------------------
    always_ff @(posedge clk) begin
        unique case (state)
            STATE_IDLE: begin
                if (start_perm_i) rnd_cnt <= round_config_i ? 4'd0 : 4'd4;
                if (write_en_i) state_array[word_sel_i] <= data_i;
            end

            STATE_PERM: begin
                state_array <= diffusion_state_array_o;
                if (rnd_cnt < 4'd11) rnd_cnt <= rnd_cnt + 4'd1;
            end
        endcase
    end

    // Combinational Output Data
    assign data_o = state_array[word_sel_i];

endmodule
