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

    logic [31:0] word_cnt, next_word_cnt; // Widened to 32-bit for XOF lengths
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
            word_cnt  <= 32'd0;
        end else begin
            state     <= next_state;
            phase_reg <= next_phase;
            word_cnt  <= next_word_cnt;
        end
    end

// =======================================================================
    // NEXT STATE DECODER
    // =======================================================================
    always_comb begin
        // Default Values
        next_state    = state;
        next_word_cnt = word_cnt;
        next_phase    = phase_reg;

        unique case (state)
            STATE_IDLE: begin
                if (start_i) begin
                    next_state = STATE_INIT;
                    next_phase = PHASE_ABSORB;
                end
            end

            STATE_INIT: begin
                if (word_cnt == 32'd4) begin
                    next_word_cnt = 32'd0;
                    next_state    = STATE_PERM_START; // Permute the IV
                end else begin
                    next_word_cnt = word_cnt + 32'd1;
                end
            end

            STATE_PERM_START: begin
                next_state = STATE_PERM_WAIT;
            end

            STATE_PERM_WAIT: begin
                if (ascon_ready_i) begin
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
                    if (padded_tlast_i) begin
                        next_phase    = PHASE_SQUEEZE;
                        next_word_cnt = 32'd0;
                    end
                end
            end

            STATE_SQUEEZE: begin
                if (m_axis_tready_i && m_axis_tvalid_o) begin
                    next_word_cnt = word_cnt + 32'd1;
                    // Check Termination Conditions (Hash256=4 words, or XOF Abort/Length)
                    if (abort_i || (xof_len_i > 0 && next_word_cnt == target_squeeze_words)) begin
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
        round_config_o     = 1'b0; // 0 = p^12 for Ascon-Hash/XOF
        write_en_o         = 1'b0;
        word_sel_o         = word_cnt[2:0];
        core_in_data_sel_o = DATA_IN_HASH_SEL; // Default to FSM data
        xor_sel_o          = XOR_IN_AXI_SEL;
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
                if (word_cnt == 32'd0) begin
                    unique case (mode_i)
                        MODE_XOF:     data_o = ASCON_XOF_IV_WORD0;
                        MODE_CXOF:    data_o = ASCON_CXOF_IV_WORD0;
                        default:      data_o = ASCON_HASH_IV_WORD0;
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
                    core_in_data_sel_o = DATA_IN_XOR_SEL;
                end
            end

            STATE_SQUEEZE: begin
                m_axis_tvalid_o = 1'b1;
                word_sel_o      = 3'd0; // Squeeze ONLY from S0

                // Assert TLAST on the final beat (if not in continuous mode)
                if (abort_i || (xof_len_i > 0 && (word_cnt + 32'd1 == target_squeeze_words))) begin
                    m_axis_tlast_o = 1'b1;
                end
            end

            STATE_DONE: begin
                done_o = 1'b1;
            end

            default: ;
        endcase
    end

endmodule
