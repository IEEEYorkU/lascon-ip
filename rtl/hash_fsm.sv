/* =============================================================================
 * Module Name: hash_fsm
 * Author(s):   Ailiya Jafri, Kiet Le
 * Reference:   NIST SP 800-232 (Algorithm 5)
 * * -----------------------------------------------------------------------------
 * 1. HIGH-LEVEL DESCRIPTION
 * -----------------------------------------------------------------------------
 * Control path orchestrator for Ascon-Hash256, Ascon-XOF128, and Ascon-CXOF128.
 * This FSM acts as the bridge between the decoupled AXI4-Stream Padder and the
 * 320-bit Ascon permutation datapath, safely managing the Sponge construction's
 * Rate and Capacity lanes during data transfer.
 *
 * -----------------------------------------------------------------------------
 * 2. SUPPORTED MODES & PARAMETERS
 * -----------------------------------------------------------------------------
 * - MODE_HASH256: Standard hashing. Produces a fixed 256-bit (4-word) digest.
 * - MODE_XOF:     Extendable output. Digest length is controlled by xof_len_i.
 * If xof_len_i == 0, the FSM enters infinite continuous squeeze.
 * - MODE_CXOF:    Customizable XOF. Requires a Customization String (Z) to be
 * absorbed prior to the main Message (M).
 *
 * -----------------------------------------------------------------------------
 * 3. EXPECTED USAGE FLOW (PROTOCOL)
 * -----------------------------------------------------------------------------
 * STEP 1: Initialization
 * Set `mode_i` and `xof_len_i`, then pulse `start_i`.
 * The FSM automatically loads the correct 320-bit pre-computed IV
 * into the Ascon Core, permutes it, and enters the Absorb phase.
 *
 * STEP 2: Customization (MODE_CXOF Only)
 * Stream the customization string (Z) tagged with `TUSER_Z`.
 * Assert `padded_tlast_i` on the final beat. The FSM will permute
 * the sponge and automatically return to the Absorb phase.
 *
 * STEP 3: Message Absorption
 * Stream the message (M) tagged with `TUSER_MSG`.
 * Assert `padded_tlast_i` on the final beat. The FSM will permute
 * the sponge and transition to the Squeeze phase.
 *
 * STEP 4: Squeezing
 * The FSM drives `m_axis_tvalid_o` high and outputs 64-bit digest
 * words, triggering intermediate permutations automatically.
 * It asserts `m_axis_tlast_o` on the final requested word.
 * (Note: For infinite XOF streams, pulse `abort_i` to terminate).
 * ============================================================================= */

`timescale 1ns / 1ps
import lascon_pkg::*;

module hash_fsm (
    input  logic           clk,
    input  logic           rst,

    // -----------------------------------------------------------------------
    // Hash FSM Control I/O
    // -----------------------------------------------------------------------
    input  lascon_mode_t   mode_i,
    input  logic [31:0]    xof_len_i,     // 0 = Infinite/Continuous Mode, else specific byte length
    input  logic           start_i,
    input  logic           abort_i,       // Pulse high to terminate continuous squeezing
    output logic           busy_o,
    output logic           done_o,

    // -----------------------------------------------------------------------
    // Ascon Core Control I/O
    // -----------------------------------------------------------------------
    input  logic           lascon_ready_i,
    output logic           start_perm_o,
    output logic           round_config_o, // e.g., 0 for p^12, 1 for p^8
    output logic [2:0]     word_sel_o,
    output ascon_word_t    data_o,         // Used to write the pre-computed Hash IVs
    output logic           write_en_o,
    output data_sel_t      core_in_data_sel_o,

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
    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_INIT,
        STATE_PERM_START,
        STATE_PERM_WAIT,
        STATE_ABSORB,
        STATE_SQUEEZE,
        STATE_DONE
    } state_t;

    // Track whether the next permutation returns to Absorb or Squeeze
    typedef enum logic {
        PHASE_ABSORB  = 1'b0,
        PHASE_SQUEEZE = 1'b1
    } phase_t;

    state_t state, next_state;
    phase_t phase_reg, next_phase;

    logic [2:0]  word_cnt, next_word_cnt;
    logic [31:0] words_remaining_r, next_words_remaining;
    logic        abort_latch;
    logic [31:0] target_squeeze_words;

    // Calculate how many 64-bit words to squeeze based on xof_len_i (in bytes)
    assign target_squeeze_words = (mode_i == MODE_HASH256) ? 32'd4 : ((xof_len_i + 32'd7) >> 3);

    localparam ascon_word_t ASCON_HASH_IV_WORD0  = 64'h0000080100cc0002;
    localparam ascon_word_t ASCON_XOF_IV_WORD0   = 64'h0000080000cc0003;
    localparam ascon_word_t ASCON_CXOF_IV_WORD0  = 64'h0000080000cc0004;

    // =======================================================================
    // STATE REGISTER UPDATES
    // =======================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= STATE_IDLE;
            phase_reg <= PHASE_ABSORB;
            word_cnt  <= 3'd0;
            words_remaining_r <= 32'd0;
        end else begin
            state     <= next_state;
            phase_reg <= next_phase;
            word_cnt  <= next_word_cnt;
            words_remaining_r <= next_words_remaining;

            // Capture abort pulse and latch until the next operation or IDLE
            if (state == STATE_IDLE) begin
                abort_latch <= 1'b0;
            end else begin
                abort_latch <= abort_latch | abort_i;
            end
        end
    end

// =======================================================================
    // NEXT STATE DECODER
    // =======================================================================
    always_comb begin
        // Default Values
        next_state           = state;
        next_word_cnt        = word_cnt;
        next_words_remaining = words_remaining_r;
        next_phase           = phase_reg;

        unique case (state)
            STATE_IDLE: begin
                if (start_i) begin
                    next_state           = STATE_INIT;
                    next_phase           = PHASE_ABSORB;
                    next_word_cnt        = 3'd0;
                    next_words_remaining = target_squeeze_words;
                end
            end

            STATE_INIT: begin
                if (word_cnt == 3'd4) begin
                    next_word_cnt = 3'd0;
                    next_state    = STATE_PERM_START; // Permute the IV
                end else begin
                    next_word_cnt = word_cnt + 3'd1;
                end
            end

            STATE_PERM_START: begin
                next_state = STATE_PERM_WAIT;
            end

            STATE_PERM_WAIT: begin
                if (lascon_ready_i) begin
                    // Use the phase tracker to return to the correct loop
                    if (phase_reg == PHASE_ABSORB) begin
                        next_state = STATE_ABSORB;
                    end else begin
                        next_state = STATE_SQUEEZE;
                    end
                end
            end

            STATE_ABSORB: begin
                if (padded_tvalid_i && padded_tready_o) begin
                    next_state = STATE_PERM_START; // Hash permutes after EVERY block

                    // PHASE DECISION:
                    // If TLAST is high, we normally transition to SQUEEZE.
                    // EXCEPTION (CXOF): If the packet is a Customization String (TUSER_Z),
                    // we must return to ABSORB to process the actual Message next.
                    if (padded_tlast_i && padded_tuser_i != TUSER_Z) begin
                        next_phase    = PHASE_SQUEEZE;
                    end else begin
                        next_phase    = PHASE_ABSORB;
                    end
                end
            end

            STATE_SQUEEZE: begin
                if (m_axis_tready_i) begin
                    next_words_remaining = words_remaining_r - 32'd1;
                    // Check Termination Conditions (Hash256=4 words, or XOF Abort/Length)
                    if (abort_i || abort_latch || ((mode_i == MODE_HASH256 || xof_len_i > 0) && words_remaining_r == 32'd1)) begin
                        next_state = STATE_DONE;
                    end else begin
                        next_state = STATE_PERM_START; // Permute between EVERY squeeze block
                        next_phase = PHASE_SQUEEZE;
                    end
                end
            end

            STATE_DONE: begin
                next_state = STATE_IDLE;
            end
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
        round_config_o     = 1'b1; // 1 = p^12 for Ascon-Hash/XOF
        write_en_o         = 1'b0;
        word_sel_o         = word_cnt[2:0];
        core_in_data_sel_o = DATA_IN_HASH_SEL; // Default to FSM data
        padded_tready_o    = 1'b0;
        m_axis_tvalid_o    = 1'b0;
        m_axis_tlast_o     = 1'b0;
        m_axis_tkeep_o     = 8'hFF;
        m_axis_tuser_o     = TUSER_DIGEST;
        data_o             = 64'b0;

        unique case (state)
            STATE_IDLE: begin
                busy_o = 1'b0;
            end

            STATE_INIT: begin
                write_en_o = 1'b1;
                // Initialize Core S0 with IV
                if (word_cnt == 3'd0) begin
                    unique case (mode_i)
                        MODE_XOF:     data_o = ASCON_XOF_IV_WORD0;
                        MODE_CXOF:    data_o = ASCON_CXOF_IV_WORD0;
                        MODE_HASH256: data_o = ASCON_HASH_IV_WORD0;
                        MODE_AEAD_ENC,
                        MODE_AEAD_DEC: data_o = 64'b0;
                    endcase
                // Initialize Core S1/S2/S3/S4 with 0
                end else begin
                    data_o = 64'b0;
                end
            end

            STATE_PERM_START: begin
                start_perm_o = 1'b1; // Safe 1-cycle trigger pulse
            end

            STATE_PERM_WAIT: begin
                // Hold idle while waiting for core
            end

            STATE_ABSORB: begin
                padded_tready_o = 1'b1;
                if (padded_tvalid_i) begin
                    write_en_o         = 1'b1;
                    word_sel_o         = 3'd0; // Hash absorbs ONLY into S0
                    core_in_data_sel_o = DATA_IN_XOR_AXI_SEL;
                end
            end

            STATE_SQUEEZE: begin
                m_axis_tvalid_o = 1'b1;
                word_sel_o      = 3'd0; // Squeeze ONLY from S0

                // Assert TLAST on the final beat independent of READY to ensure stability.
                // Include the abort latch to safely terminate even if the abort pulse arrives while stalled.
                m_axis_tlast_o = (abort_i || abort_latch || ((mode_i == MODE_HASH256 || xof_len_i > 0) && (words_remaining_r == 32'd1)));
            end

            STATE_DONE: begin
                done_o = 1'b1;
            end
        endcase
    end

endmodule
