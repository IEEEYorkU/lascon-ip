/* =============================================================================
 * Module Name: ascon_padder
 * Author(s):   Kiet Le, Tirth Patel, Kevin Duong
 * Description:
 * AXI4-Stream pre-processor (Data Formatter/Framer) for the Ascon Hardware
 * Accelerator. This module acts as a pipeline stage between the raw external
 * AXI4-Stream data and the internal protocol-specific FSMs (AEAD and Hash).
 *
 * Architecture & Role:
 * By intercepting the raw AXI stream, this module abstracts away the complex
 * bit-level padding and rate-alignment rules of the NIST SP 800-232 standard.
 * This allows the downstream sub-FSMs to act as incredibly simple block-counters
 * that only trigger permutations when they see `padded_tlast == 1`.
 *
 * Key Responsibilities & Design Requirements:
 * * 1. The Ascon Padding Rule (TKEEP Translation)
 * - Ascon requires a single `1` bit appended immediately after the last
 * valid byte of a message, followed by `0`s to fill the block.
 * - The padder monitors `s_axis_tkeep` on the final word (`s_axis_tlast == 1`).
 * - It dynamically masks the invalid bytes and injects the `1000...0` bit
 * pattern. It then outputs `padded_tkeep = 8'hFF` so the FSMs do not
 * need to handle fractional bytes.
 *
 * 2. Rate Alignment State Machine (The 64-bit vs 128-bit Challenge)
 * - Ascon-Hash256 uses a 64-bit rate (1 word).
 * - Ascon-AEAD128 uses a 128-bit rate (2 words).
 * - If `mode_i` is AEAD, and a padded message ends perfectly on the *first*
 *   64-bit word of the 128-bit block, the padder must NOT assert `padded_tlast`.
 * - Instead, it must halt the upstream stream (`s_axis_tready = 0`), stall
 * for one clock cycle, output a *second* 64-bit word of pure `0`s, and
 * then assert `padded_tlast = 1` to tell the AEAD FSM the block is full.
 *
 * 3. TUSER Packet Filtering & The Decryption Exception
 * The module routes and modifies data strictly based on the `s_axis_tuser` flag:
 * * - GROUP A (Pass-through): TUSER_KEY, TUSER_NONCE, TUSER_TAG.
 * Action: Pass data and tlast through unmodified. Do not apply padding.
 * * - GROUP B (Pad on TLAST): TUSER_AD, TUSER_PT, TUSER_MSG, TUSER_Z.
 * Action: When `tlast == 1`, consume `tkeep`, apply the Ascon bit-padding
 * rule, handle rate alignment, and output `padded_tkeep = 8'hFF`.
 * * - GROUP C (The Decryption Exception): TUSER_CT (Ciphertext).
 * Action: STRICT PASS-THROUGH. Do not apply padding. Do not alter `tkeep`.
 * Why? During decryption, the AEAD FSM needs the exact fractional Ciphertext
 * bytes to overwrite the state, AND it needs the raw `TKEEP` signal to know
 * exactly where (\ell) to manually inject the padding bits via XOR.
 *
 * Ref: NIST SP 800-232 (Algorithm 4 Decryption, Algorithm 5 Hashing)
 * ============================================================================= */

`timescale 1ns / 1ps

import ascon_pkg::*;

module ascon_padder (
    input  logic          clk,
    input  logic          rst,

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------
    input  ascon_mode_t   mode_i,

    // -----------------------------------------------------------------------
    // Raw AXI4-Stream Slave (Data FROM Outside World)
    // -----------------------------------------------------------------------
    input  ascon_word_t   s_axis_tdata_i,  // Raw data input
    input  logic [7:0]    s_axis_tkeep_i,  // Byte enable mask, indicates valid bytes in the last word
    input  axi_tuser_t    s_axis_tuser_i,  // Identifies the type of data (AD, PT, MSG, KEY, NONCE, TAG, CT, Z)
    input  logic          s_axis_tlast_i,  // High on the final word of the packet
    input  logic          s_axis_tvalid_i, // Indicates that the input data is valid
    output logic          s_axis_tready_o, // Tells the source to stop if the padder is not ready to accept data

    // -----------------------------------------------------------------------
    // Padded AXI4-Stream Master (Data TO Top-Level Mux -> FSMs/Core)
    // -----------------------------------------------------------------------
    output ascon_word_t   padded_tdata_o,  // Post processes 64 bit word with Acson padding rules applied
    output logic [7:0]    padded_tkeep_o,  // Forced to 8'hFF, EXCEPT for TUSER_CT
    output axi_tuser_t    padded_tuser_o,  // Forwared or held metadata tag to maintain packet context
    output logic          padded_tlast_o,  // High only when the block is fully rate-aligned
    output logic          padded_tvalid_o, // Indicates packet is ready for the next stage (FSMs/Core)
    input  logic          padded_tready_i  // Allows the core to stall the padder if it is not ready to accept data
);

    // =======================================================================
    // INTERNAL LOGIC DECLARATIONS
    // =======================================================================
    typedef enum logic [1:0] {
        STATE_IDLE_PASS = 2'b00,
        STATE_PAD_WORD1 = 2'b01,
        STATE_PAD_WORD2 = 2'b10
    } padder_state_t;

    padder_state_t state, next_state;

    //internal tracking for the 128 bit (2 word) block alignment
    // word_count = 0: First 64 bits of a block
    // word_count = 1: Second 64 bits of a block
    logic word_count_reg, word_count_next;

    //determine if the current TUSER group requires padding or not
    logic is_padding_group; // (AD, PT, MSG, Z)
    assign is_padding_group = (s_axis_tuser_i == TUSER_AD ||
                               s_axis_tuser_i == TUSER_PT ||
                               s_axis_tuser_i == TUSER_MSG ||
                               s_axis_tuser_i == TUSER_Z);

    // -----------------------------------------------------------------------
    // 1. Padding Generator (The 1000...0 Bit Injection Logic)
    // -----------------------------------------------------------------------
    ascon_word_t masked_data, pad_word2_data_next, pad_word2_data_reg;
    axi_tuser_t held_tuser_next, held_tuser_reg;

    logic is_aead_mode; //AEAD mode helper
    assign is_aead_mode = ((mode_i == MODE_AEAD_ENC) || (mode_i == MODE_AEAD_DEC));

    // Icarus does not support variable part-selects ([i*8 +: 8]) or break
    // inside always_comb. The padding logic is therefore implemented as a
    // function and wired via assign, which Icarus handles without restriction.
    // The case enumerates every contiguous tkeep pattern Ascon can produce:
    //   tkeep = 8'h00..8'h7F → inject 0x80 at the first invalid byte position
    //   tkeep = 8'hFF        → full word, no padding here (carry word handles it)
    function automatic ascon_word_t apply_padding(
        input ascon_word_t data,
        input logic [7:0]  keep
    );
        case (keep)
            8'h00:   apply_padding = {56'h00_00_00_00_00_00_00, 8'h80};                   // 0 valid bytes
            8'h01:   apply_padding = {48'h00_00_00_00_00_00,    8'h80, data[7:0]};        // 1 valid byte
            8'h03:   apply_padding = {40'h00_00_00_00_00,       8'h80, data[15:0]};       // 2 valid bytes
            8'h07:   apply_padding = {32'h00_00_00_00,          8'h80, data[23:0]};       // 3 valid bytes
            8'h0F:   apply_padding = {24'h00_00_00,             8'h80, data[31:0]};       // 4 valid bytes
            8'h1F:   apply_padding = {16'h00_00,                8'h80, data[39:0]};       // 5 valid bytes
            8'h3F:   apply_padding = { 8'h00,                   8'h80, data[47:0]};       // 6 valid bytes
            8'h7F:   apply_padding = {                          8'h80, data[55:0]};       // 7 valid bytes
            default: apply_padding = data; //8'hFF full word, no padding here (carry word handles it)
        endcase
    endfunction

    // Power-Optimized Operand Isolation
    always_comb begin
        // Default: Pass data through
        masked_data = s_axis_tdata_i;

        // OPERAND ISOLATION:
        // Only wake up and toggle the 64-bit padding multiplexers if we are
        // actively receiving a valid, partial final-word of a padding group.
        // This saves massive dynamic power during long CT/PT/MSG streams.
        if (s_axis_tvalid_i && is_padding_group && s_axis_tlast_i && (s_axis_tkeep_i != 8'hFF)) begin
            masked_data = apply_padding(s_axis_tdata_i, s_axis_tkeep_i);
        end
    end

    // -----------------------------------------------------------------------
    // 2. State Machine Logic
    // -----------------------------------------------------------------------

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= STATE_IDLE_PASS;
            held_tuser_reg <= TUSER_RESERVED;
            pad_word2_data_reg <= '0;
            word_count_reg <= 1'b0;
        end else begin
            state <= next_state;
            held_tuser_reg <= held_tuser_next;
            pad_word2_data_reg <= pad_word2_data_next;
            word_count_reg <= word_count_next;
        end
    end

    always_comb begin
        // Default values for outputs and next state
        next_state = state;
        word_count_next = word_count_reg;

        held_tuser_next     = held_tuser_reg;
        pad_word2_data_next = pad_word2_data_reg;

        s_axis_tready_o = padded_tready_i;
        padded_tvalid_o = s_axis_tvalid_i;
        padded_tdata_o = s_axis_tdata_i;
        padded_tkeep_o = s_axis_tkeep_i;
        padded_tuser_o = s_axis_tuser_i;
        padded_tlast_o = s_axis_tlast_i;

        case (state)
            STATE_IDLE_PASS: begin
                if (is_padding_group) begin
                    // Padding groups are always delivered as full words downstream.
                    padded_tkeep_o = 8'hFF;
                end

                if (s_axis_tvalid_i && padded_tready_i) begin
                    if (is_padding_group) begin
                        if (s_axis_tlast_i) begin
                            //Final part of a padding-group packet
                            held_tuser_next = s_axis_tuser_i;
                            word_count_next = 1'b0;

                            if (s_axis_tkeep_i == 8'hFF) begin
                                // Full final word: 0x80 must carry into generated word(s).
                                if (is_aead_mode) begin
                                    if (word_count_reg == 1'b0) begin
                                        // AEAD word0 full-final: generate word1 = 0x80..., then end block.
                                        padded_tlast_o      = 1'b0;
                                        pad_word2_data_next = 64'h8000_0000_0000_0000;
                                        next_state          = STATE_PAD_WORD2;
                                    end else begin
                                        // AEAD word1 full-final: current block ends, then emit [0x80...][0x00...].
                                        padded_tlast_o      = 1'b1;
                                        pad_word2_data_next = 64'h0000_0000_0000_0000;
                                        next_state          = STATE_PAD_WORD1;
                                    end
                                end else begin
                                    // HASH/XOF/CXOF full-final: emit current block, then one carry block 0x80...
                                    padded_tlast_o      = 1'b1;
                                    pad_word2_data_next = 64'h8000_0000_0000_0000;
                                    next_state          = STATE_PAD_WORD2;
                                end
                            end else begin
                                //padding fits into current final word.
                                padded_tdata_o = masked_data;

                                if (is_aead_mode && (word_count_reg == 1'b0)) begin
                                    // AEAD ended on word0: generate zero word1 to align 128-bit rate.
                                    padded_tlast_o      = 1'b0;
                                    pad_word2_data_next = 64'h0000_0000_0000_0000;
                                    next_state          = STATE_PAD_WORD2;
                                end else begin
                                    // HASH/XOF/CXOF always ends here; AEAD word1 also ends here.
                                    padded_tlast_o = 1'b1;
                                end
                            end
                        end else begin
                            // Non-final beat bookkeeping for AEAD block alignment.
                            word_count_next = is_aead_mode ? ~word_count_reg : 1'b0;
                        end
                    end
                end
            end

            STATE_PAD_WORD1: begin
                // Emit generated word0 for the AEAD two-word carry sequence.
                s_axis_tready_o = 1'b0;
                padded_tvalid_o = 1'b1;
                padded_tdata_o  = 64'h8000_0000_0000_0000;
                padded_tkeep_o  = 8'hFF;
                padded_tuser_o  = held_tuser_reg;
                padded_tlast_o  = 1'b0;

                if (padded_tready_i) begin
                    next_state = STATE_PAD_WORD2;
                end
            end

           STATE_PAD_WORD2: begin
                // Emit single carry word, or generated AEAD word1.
                s_axis_tready_o = 1'b0;
                padded_tvalid_o = 1'b1;
                padded_tdata_o  = pad_word2_data_reg;
                padded_tkeep_o  = 8'hFF;
                padded_tuser_o  = held_tuser_reg;
                padded_tlast_o  = 1'b1;

                if (padded_tready_i) begin
                    next_state      = STATE_IDLE_PASS;
                    word_count_next = 1'b0;
                end
            end

            default: next_state = STATE_IDLE_PASS;
        endcase
    end
endmodule
