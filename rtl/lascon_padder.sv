/* =============================================================================
 * Module Name: lascon_padder
 * Author(s):   Kiet Le, Tirth Patel, Kevin Duong
 * Description:
 * AXI4-Stream pre-processor and framer for the Lascon Hardware Accelerator.
 *
 * Key Responsibilities:
 * 1. Endian Swap: Converts external Little-Endian AXI data to internal Big-Endian.
 * 2. Padding Injection: Appends Ascon's '10...0' pad to partial words (AD, PT, MSG, Z).
 * 3. Rate Alignment: Manages 64-bit (Hash) vs 128-bit (AEAD) block boundaries,
 *    automatically generating zero-padded filler words when needed.
 * 4. Pass-Through & Sidebands: Leaves unpadded streams (KEY, NONCE, CT) untouched
 *    to allow downstream FSMs to process fractional bytes directly. Provides raw
 *    stream byte-enables (padded_tkeep_raw_o) and padding indicator flags
 *    (padded_is_padding_o) to assist downstream FSM state updates and masking.
 * ============================================================================= */

`timescale 1ns / 1ps

import lascon_pkg::*;

module lascon_padder (
    input  logic          clk,
    input  logic          rst,

    // Configuration
    input  lascon_mode_t  mode_i,

    // Raw AXI4-Stream Slave (Data FROM Outside World - LITTLE ENDIAN)
    input  ascon_word_t   s_axis_tdata_i,
    input  logic [7:0]    s_axis_tkeep_i,
    input  axi_tuser_t    s_axis_tuser_i,
    input  logic          s_axis_tlast_i,
    input  logic          s_axis_tvalid_i,
    output logic          s_axis_tready_o,

    // --- AXI4-Stream Master (Data going OUT) ---
    output ascon_word_t         padded_tdata_o,
    output logic [7:0]          padded_tkeep_raw_o, // Raw pass-through for exact Payload tracking
    output axi_tuser_t          padded_tuser_o,
    output logic                padded_tlast_o,
    output logic                padded_tvalid_o,
    output logic                padded_is_padding_o, // High when emitting artificial carry blocks
    input  logic                padded_tready_i
);

    // =======================================================================
    // INTERNAL LOGIC DECLARATIONS
    // =======================================================================
    typedef enum logic [1:0] {
        STATE_IDLE_PASS = 2'b00,
        STATE_PAD_WORD1 = 2'b01, // Generates AEAD alignment zeros
        STATE_PAD_WORD2 = 2'b10  // Generates 0x80... carry blocks
    } padder_state_t;

    padder_state_t state, next_state;

    // Tracks 128-bit block alignment for AEAD (0 = 1st word, 1 = 2nd word)
    logic word_count_reg, word_count_next;

    // Identifies TUSER groups that require Ascon padding
    logic is_padding_group;
    assign is_padding_group = (s_axis_tuser_i == TUSER_AD ||
                               s_axis_tuser_i == TUSER_PT ||
                               s_axis_tuser_i == TUSER_MSG ||
                               s_axis_tuser_i == TUSER_Z);

    logic is_aead_mode;
    assign is_aead_mode = ((mode_i == MODE_AEAD_ENC) || (mode_i == MODE_AEAD_DEC));
    logic pad_word2_is_80_reg, pad_word2_data_next;
    // Registers for multi-cycle padding generation
    ascon_word_t masked_data;
    axi_tuser_t held_tuser_next, held_tuser_reg;

    // -----------------------------------------------------------------------
    // 1. Endianness & Padding Generators
    // -----------------------------------------------------------------------



    // Converts LE AXI data directly into padded BE Ascon data based on TKEEP
    function automatic ascon_word_t apply_padding(
        input ascon_word_t data,
        input logic [7:0]  keep
    );
        case (keep)
            8'h00:   apply_padding = {8'h80, 56'h00_00_00_00_00_00_00};
            8'h01:   apply_padding = {data[7:0], 8'h80, 48'h00_00_00_00_00_00};
            8'h03:   apply_padding = {data[7:0], data[15:8], 8'h80, 40'h00_00_00_00_00};
            8'h07:   apply_padding = {data[7:0], data[15:8], data[23:16], 8'h80, 32'h00_00_00_00};
            8'h0F:   apply_padding = {data[7:0], data[15:8], data[23:16], data[31:24], 8'h80, 24'h00_00_00};
            8'h1F:   apply_padding = {data[7:0], data[15:8], data[23:16], data[31:24], data[39:32], 8'h80, 16'h00_00};
            8'h3F:   apply_padding = {data[7:0], data[15:8], data[23:16], data[31:24], data[39:32], data[47:40], 8'h80, 8'h00};
            8'h7F:   apply_padding = {data[7:0], data[15:8], data[23:16], data[31:24], data[39:32], data[47:40], data[55:48], 8'h80};
            default: apply_padding = swap_bytes(data);
        endcase
    endfunction

    // Power Optimization: Only compute padding on valid, final, partial words
    // belonging to a padding group. Otherwise, just execute the byte-swap.
    always_comb begin
        masked_data = swap_bytes(s_axis_tdata_i);

        if (s_axis_tvalid_i && is_padding_group && s_axis_tlast_i && (s_axis_tkeep_i != 8'hFF)) begin
            masked_data = apply_padding(s_axis_tdata_i, s_axis_tkeep_i);
        end
    end

    // -----------------------------------------------------------------------
    // 2. Rate Alignment & Carry FSM
    // -----------------------------------------------------------------------

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state              <= STATE_IDLE_PASS;
            held_tuser_reg     <= TUSER_RESERVED;
            pad_word2_is_80_reg <= '0;
            word_count_reg     <= 1'b0;
        end else begin
            state              <= next_state;
            held_tuser_reg     <= held_tuser_next;
            pad_word2_is_80_reg <= pad_word2_data_next;
            word_count_reg     <= word_count_next;
        end
    end

    always_comb begin
        next_state          = state;
        word_count_next     = word_count_reg;
        held_tuser_next     = held_tuser_reg;
        pad_word2_data_next = pad_word2_is_80_reg;

        // Default Pass-Through Assignments
        s_axis_tready_o = padded_tready_i;
        padded_tvalid_o = s_axis_tvalid_i;
        padded_tdata_o  = masked_data;
        padded_tkeep_raw_o = s_axis_tkeep_i; // Unconditionally pass the raw TKEEP
        padded_tuser_o  = s_axis_tuser_i;
        padded_tlast_o  = s_axis_tlast_i; // Defaults to transparent pass-through (CT, KEY)
        padded_is_padding_o = 1'b0;

        case (state)
            STATE_IDLE_PASS: begin
                if (is_padding_group) begin
                    // Downstream block-counters expect full words (no fractional TKEEP)

                    // Override TLAST based on rate alignment needs.
                    // NOTE: TLAST is driven combinationally and IS NOT guarded by READY.
                    // This is intentional to comply with AXI4-Stream stability rules:
                    // TLAST must remain stable while VALID is high and READY is low.
                    // Downstream logic MUST only sample TLAST on a successful handshake.
                    if (s_axis_tvalid_i && s_axis_tlast_i) begin
                        if (s_axis_tkeep_i == 8'hFF) begin
                            // Full word requires a spillover carry block, so delay TLAST.
                            padded_tlast_o = 1'b0;
                        end else begin
                            // Partial word (or 0-byte word) absorbs the 0x80 padding perfectly.
                            // Exception: AEAD word 0 needs a subsequent zero-word to align 128 bits.
                            if (is_aead_mode && word_count_reg == 1'b0) padded_tlast_o = 1'b0;
                            else padded_tlast_o = 1'b1;
                        end
                    end

                    // FSM Transitions & Carry-Block Generation
                    if (s_axis_tvalid_i && padded_tready_i) begin
                        if (s_axis_tlast_i) begin
                            held_tuser_next = s_axis_tuser_i;
                             // Reset word count on TLAST to ensure the next packet starts at word 0.
                             // This assumes the upstream producer respects packet boundaries.
                             word_count_next = 1'b0;

                            if (s_axis_tkeep_i == 8'hFF) begin
                                if (is_aead_mode) begin
                                    if (word_count_reg == 1'b0) begin
                                        // AEAD Word 0 full: Follow with 0x80 carry block
                                        // Changed to signal for 0x80
                                        pad_word2_data_next = 1'b1;
                                        next_state          = STATE_PAD_WORD2;
                                    end else begin
                                        // AEAD Word 1 full: Start new block with [0x80] then [0x00]
                                        pad_word2_data_next = 1'b0;
                                        next_state          = STATE_PAD_WORD1;
                                    end
                                end else begin
                                    // HASH/XOF full: Follow with 0x80 carry block
                                    pad_word2_data_next = 1'b1;
                                    next_state          = STATE_PAD_WORD2;
                                end
                            end else begin
                                if (is_aead_mode && (word_count_reg == 1'b0)) begin
                                    // AEAD Word 0 partial: Follow with zero-block to align 128-bit boundary
                                    pad_word2_data_next = 1'b0;
                                    next_state          = STATE_PAD_WORD2;
                                end
                            end
                        end else begin
                            // Toggle AEAD word count on non-last beats
                            word_count_next = is_aead_mode ? ~word_count_reg : 1'b0;
                        end
                    end
                end
            end

            STATE_PAD_WORD1: begin
                // WORD1: Emits the NIST SP 800-232 mandatory Ascon padding bit (0x80)
                // to start a new supplemental block when the rate r=128 is perfectly full.
                s_axis_tready_o = 1'b0;
                padded_tvalid_o = 1'b1;
                padded_tdata_o  = 64'h8000_0000_0000_0000;
                padded_tkeep_raw_o = 8'h00; // Synthetic word has no real payload
                padded_tuser_o  = held_tuser_reg;
                padded_tlast_o  = 1'b0;
                padded_is_padding_o = 1'b1;

                if (padded_tready_i) begin
                    next_state = STATE_PAD_WORD2;
                end
            end

           STATE_PAD_WORD2: begin
                // WORD2: Emits the final 64-bit padding word (either the 0x80 carrier for r=64
                // or a zero-filler for r=128) to complete the NIST SP 800-232 rate multiple.
                s_axis_tready_o = 1'b0;
                padded_tvalid_o = 1'b1;
                padded_tdata_o  = {pad_word2_is_80_reg, 63'b0};
                padded_tkeep_raw_o = 8'h00; // Synthetic word has no real payload
                padded_tuser_o  = held_tuser_reg;
                padded_tlast_o  = 1'b1;
                padded_is_padding_o = 1'b1;

                if (padded_tready_i) begin
                    next_state      = STATE_IDLE_PASS;
                    word_count_next = 1'b0;
                end
            end

            default: next_state = STATE_IDLE_PASS;
        endcase
    end

    // =======================================================================
    // Safety Assertions (Simulation Only)
    // =======================================================================
    // pragma translate_off
    assert_axis_not_null: assert property (
        @(posedge clk) disable iff (rst)
        // AXI4-Stream Protocol Violation: Null transport (TVALID with TKEEP=0)
        // is generally illegal, but we allow it specifically on TLAST=1
        // to signal the end of a (possibly empty) message.
        !(s_axis_tvalid_i && s_axis_tkeep_i == 8'h00 && !s_axis_tlast_i)
    ) else $error("lascon_padder: Detected middle-of-stream TVALID with TKEEP=0. This is semantically invalid.");
    // pragma translate_on

endmodule
