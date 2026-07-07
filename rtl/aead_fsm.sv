/* Module Name: aead_fsm
 * Author(s):  Rayhaan, Tommy, Arthur
 * Description: Ascon-AEAD128 Protocol Orchestrator FSM
 * The protocol orchestrator ("The Brain") for the Ascon-AEAD128 Authenticated
 * Encryption and Decryption Accelerator. This module implements Algorithm 3
 * (Authenticated Encryption) and Algorithm 4 (Authenticated Decryption) as
 * defined in NIST SP 800-232, coordinating all cryptographic phases from
 * initialization through tag generation and verification.
 *
 * Design Philosophy (Pure Protocol Sequencer):
 * This FSM is designed as a stateless control-path orchestrator. It possesses
 * zero knowledge of the mathematical internals of the Ascon permutation. It
 * relies entirely on the ascon_core module to execute the permutation rounds,
 * and communicates with the outside world exclusively through the AXI4-Stream
 * protocol via the ascon_padder. All byte-level padding and rate-alignment
 * concerns are fully delegated to the ascon_padder, allowing this FSM to
 * operate purely at the block level.
 *
 * Implementation Details:
 * - State Machine: Implements 11 architectural states (ST_IDLE, ST_INIT,
 *   ST_PERM, ST_AD, ST_PT_IN, ST_CT_IN, ST_TAG_INIT, ST_ENC_TAG, ST_DEC_TAG,
 *   ST_VERIFY, ST_DONE) built as a split-control FSM with dedicated blocks
 *   for state register, next-state logic, sequential side registers/action
 *   latching, and output decoding.
 * - Shared Permutation State: ST_PERM is reused across all four permutation
 *   phases (initialization, associated data, processing ciphertext/plaintext, finalization). A
 *   perm_ctx_r register records which phase triggered the permutation and
 *   where to return upon completion.
 * - Post-Permutation Operations: Key XOR into S3/S4 (after CTX_INIT and
 *   CTX_FINAL) and domain separation into S4 (after CTX_AD last block) are
 *   performed within ST_PERM itself using a post_perm_cnt_r counter. For the
 *   no-AD path, domain separation is injected once in ST_AD before advancing
 *   to payload processing.
 * - Critical Spec Compliance: The final plaintext or ciphertext block does NOT
 *   trigger a permutation, per NIST SP 800-232 Algorithms 3 and 4. ST_PT_IN
 *   and ST_CT_IN transition directly to ST_TAG_INIT on padded_tlast, bypassing
 *   ST_PERM entirely for the last block.
 * - Simultaneous Data Transform and Output: During ST_PT_IN and ST_CT_IN, the
 *   FSM simultaneously reads the current state word from ascon_core (via
 *   core_data_i), computes the transformed output (CT or PT), writes the
 *   updated state back to the core, and drives the AXI master interface — all
 *   within a single clock cycle. It utilizes the padder's sideband signals to
 *   conditionally suppress outputs during padding blocks (ST_PT_IN) and perform
 *   precise byte-wise masked writes during decryption (ST_CT_IN).
 * - Tag Verification: During decryption, the received tag words are latched in
 *   ST_DEC_TAG and compared against the computed tag words (S3, S4) in
 *   ST_VERIFY over two consecutive cycles using the combinational read port
 *   of ascon_core.
 *
 * Ref: NIST SP 800-232, Section 4
 */

import lascon_pkg::*;

module aead_fsm(
    input logic                 clk,
    input logic                 rst,

    //==========================================================================
    // Mode Control
    //==========================================================================

    input lascon_mode_t         mode_i,  // Mode: ENC or DEC
    input logic                 start_i,
    output logic                busy_o,
    output logic                done_o,
    output logic                tag_fail_o, // Decryption tag check fails

    // Internal Core Interface
    input  logic                lascon_ready_i,
    input  ascon_word_t         core_data_i,   // Read state from core for Decryption/Tag
    output logic                start_perm_o,
    output logic                round_config_o,
    output logic     [2:0]      word_sel_o,  // Target state word address S0,S1,.., S4
    output ascon_word_t         data_o,
    output logic                write_en_o,
    output logic                xor_en_o,
    output data_sel_t           in_data_sel_o,  // Mux select for core data_i source

    // Padded AXI STREAM from padder unit
    input ascon_word_t          padded_tdata_i,  // Pre-processed
    input logic [7:0]           padded_tkeep_i,  // Pass - through for CT
    input logic [7:0]           padded_tkeep_raw_i, // Raw pass-through for exact Payload tracking
    input axi_tuser_t           padded_tuser_i,  // User type
    input logic                 padded_tlast_i,  // last word in the message
    input logic                 padded_tvalid_i, // valid
    input logic                 padded_is_padding_i, // High when emitting artificial carry blocks
    output logic                padded_tready_o,

    // Plaintext / Ciphertext - AX4 stream from padder unit
    output ascon_word_t         m_axis_tdata_o,
    output logic [7:0]          m_axis_tkeep_o,
    output axi_tuser_t          m_axis_tuser_o,
    output logic                m_axis_tlast_o,
    output logic                m_axis_tvalid_o,
    input  logic                m_axis_tready_i

);

    // Ascon-128a Parameters (r=128, a=12, b=8)
    localparam ascon_word_t AEAD128_IV = 64'h00001000808c0001; // IV <-  0x00001000808c0001
    localparam ascon_word_t DSEP = 64'h0000000000000001; // DSEP <- 0x0000000000000001
    localparam logic ROUND_PA = 1'b1;  // 12 round permutation
    localparam logic ROUND_PB = 1'b0;  // 8 round permutation

    typedef enum logic [3:0] {
        ST_IDLE     = 4'd0,
        ST_INIT     = 4'd1,
        ST_PERM     = 4'd2,
        ST_AD       = 4'd3,
        ST_PT_IN    = 4'd4,
        ST_CT_IN    = 4'd5,
        ST_CT_PAD_0 = 4'd6, // Inject 0x80 into word 1 when CT ends on word 0 boundary
        ST_TAG_INIT = 4'd7,
        ST_ENC_TAG  = 4'd8,
        ST_DEC_TAG  = 4'd9,
        ST_VERIFY   = 4'd10,
        ST_DONE     = 4'd11
        //ST_ERROR    = 4'd12
    } state_t;

    typedef enum logic [2:0] {
        CTX_INIT   = 3'd0, // 12 round permutation after initialization loading
        CTX_AD     = 3'd1, // 8 round permutation after each AD Block
        CTX_DATA   = 3'd2, // 8 round permutation after each non-final PT/Ct block
        CTX_CT_PAD = 3'd3, // 8 round permutation when CT ends on word 1 boundary
        CTX_FINAL  = 3'd4  // 8 round permutation during finalization
    } perm_ctx_t;

    //==========================================================================
    // Register
    //==========================================================================

    state_t    state_r;
    perm_ctx_t perm_ctx_r;

    // INIT Phase: tracks which word is being loaded into the core
    logic [2:0] init_cnt_r;

    // PERM phase management
    logic        perm_started_r;
    logic        post_perm_active_r;
    logic [1:0]  post_perm_cnt_r;

    // AD absorption
    logic    ad_word_r;
    logic    ad_last_seen_r;

    // PT/CT absorption
    logic    dat_word_r;
    logic    dat_last_seen_r;

    // Finalization
    logic [1:0] tag_init_cnt_r; // 0=K->S3 XOR, 1=K->S4 XOR, 2=transition to PERM

    // Tag output(enc) and tag receive (dexc)
    logic tag_cnt_r;  // 0=S3/T_word0, 1=S4/T_word1

    // Tag verification
    logic [1:0] verify_cnt_r;  // 0=compare S3, 1=compare S4, 2=done

    // Stored key captured during INIT
    ascon_word_t key_r[0:1];

    // dec only: received tag words
    ascon_word_t rx_tag_r[0:1];

    // tag match result
    logic tag_ok_r;

    //==========================================================================
    // Helper Functions
    //==========================================================================

    // Generates a 64-bit mask from an 8-bit LE TKEEP.
    // E.g., if TKEEP = 8'h0F (lower 4 bytes valid), it produces 64'hFFFFFFFF_00000000.
    // because TKEEP bit 0 (AXI byte 0) maps to BE byte 7 (bits 63:56).
    function automatic logic [63:0] tkeep_to_mask(input logic [7:0] tkeep);
        logic [63:0] mask;
        mask[63:56] = tkeep[0] ? 8'hFF : 8'h00;
        mask[55:48] = tkeep[1] ? 8'hFF : 8'h00;
        mask[47:40] = tkeep[2] ? 8'hFF : 8'h00;
        mask[39:32] = tkeep[3] ? 8'hFF : 8'h00;
        mask[31:24] = tkeep[4] ? 8'hFF : 8'h00;
        mask[23:16] = tkeep[5] ? 8'hFF : 8'h00;
        mask[15:8]  = tkeep[6] ? 8'hFF : 8'h00;
        mask[7:0]   = tkeep[7] ? 8'hFF : 8'h00;
        return mask;
    endfunction

    // Finds the bit index of the 0x80 padding byte to inject.
    // E.g., if TKEEP = 8'h0F, the first invalid byte is AXI byte 4.
    // AXI byte 4 maps to BE byte 3 (bits 31:24). The MSB is bit 31.
    function automatic logic [63:0] get_padding_bit(input logic [7:0] tkeep);
        logic [63:0] pad;
        pad = 64'h0;
        casex (tkeep)
            8'bxxxx_xxx0: pad[63] = 1'b1;
            8'bxxxx_xx01: pad[55] = 1'b1;
            8'bxxxx_x011: pad[47] = 1'b1;
            8'bxxxx_0111: pad[39] = 1'b1;
            8'bxxx0_1111: pad[31] = 1'b1;
            8'bxx01_1111: pad[23] = 1'b1;
            8'bx011_1111: pad[15] = 1'b1;
            8'b0111_1111: pad[7]  = 1'b1;
            default:      pad = 64'h0;
        endcase
        return pad;
    endfunction

    //==========================================================================
    // Constants & Types
    //==========================================================================

    logic is_enc;
    assign is_enc = (mode_i == MODE_AEAD_ENC);

    // Permutation complete
    logic perm_done;
    assign perm_done = perm_started_r && lascon_ready_i;

    // Padder handshake pulse
    logic phs;
    assign phs = padded_tvalid_i && padded_tready_o;

    // Max post-per counter value
    logic [1:0] pp_max;
    always_comb begin
        case (perm_ctx_r)
            CTX_INIT:  pp_max = 2'd1;
            CTX_AD:    pp_max = 2'd0;
            CTX_FINAL: pp_max = 2'd1;
            default:   pp_max = 2'd0;
        endcase
    end

    logic pp_done;
    assign pp_done = post_perm_active_r && (post_perm_cnt_r == pp_max);

    // After finishing the permutation cycle, some States require additional operations.
    // CTX_INIT_perm: XOR K into S3, S4
    // CTX_AD_perm: XOR domain separation into S4
    // CTX_FINAL_perm: XOR K into S3, S4
    logic needs_post_perm;
    assign needs_post_perm =    (perm_ctx_r == CTX_INIT)  ||
                                (perm_ctx_r == CTX_FINAL)  ||
                                (perm_ctx_r == CTX_AD && ad_last_seen_r) ||
                                (perm_ctx_r == CTX_CT_PAD);


    //==========================================================================
    // Sequential - FSM transitions and register latching
    //==========================================================================

    state_t next_state;
    always_ff @(posedge clk or posedge rst) begin
        if(rst) state_r <= ST_IDLE;
        else begin
            state_r <= next_state;
            // if (next_state != state_r) $display("Time %0t: FSM State = %0d, ctx = %0d, pad_valid = %b, pad_last = %b, pad_is_pad = %b", $time, next_state, perm_ctx_r, padded_tvalid_i, padded_tlast_i, padded_is_padding_i);
        end
    end

    //==========================================================================
    // NEXT-STATE Logic
    //==========================================================================

    logic init_ack;
    assign init_ack =   (state_r == ST_INIT) &&
                        ((init_cnt_r == 3'd0 && lascon_ready_i) ||
                        ((init_cnt_r <= 3'd2) && padded_tvalid_i && padded_tuser_i == TUSER_KEY && padded_tready_o) ||
                        ((init_cnt_r >= 3'd3 && init_cnt_r <= 3'd4) && padded_tvalid_i && padded_tuser_i == TUSER_NONCE && padded_tready_o));

    logic ad_word_valid;
    assign ad_word_valid = (state_r == ST_AD && padded_tvalid_i && padded_tuser_i == TUSER_AD && padded_tready_o);

    logic pt_word_valid;
    assign pt_word_valid = (state_r == ST_PT_IN && padded_tvalid_i && padded_tready_o);

    logic ct_word_valid;
    assign ct_word_valid = (state_r == ST_CT_IN && padded_tvalid_i && padded_tready_o);

    always_comb begin
        next_state = state_r;

        case (state_r)
            //==============================================================================
            // IDLE: Wait for start pulse from top-level controller.
            ST_IDLE: begin
                if (start_i) next_state = ST_INIT;
            end

            //==============================================================================
            // INIT: Advance after IV/K/N loading sequence completes.
            ST_INIT: begin
                if (init_cnt_r == 3'd4 && init_ack) begin
                    next_state = ST_PERM;
                end else begin
                    next_state = ST_INIT;
                end
            end

            //==============================================================================
            // PERM: Wait for permutation completion and dispatch by permutation context.
            ST_PERM: begin
                if ((perm_done && !needs_post_perm) || (post_perm_active_r && pp_done)) begin
                    case (perm_ctx_r)
                        CTX_INIT : next_state = ST_AD;
                        CTX_AD   : next_state = ad_last_seen_r ? (is_enc ? ST_PT_IN : ST_CT_IN) : ST_AD;
                        CTX_DATA : next_state = is_enc ? ST_PT_IN : ST_CT_IN;
                        CTX_CT_PAD: next_state = ST_TAG_INIT;
                        CTX_FINAL: next_state = is_enc ? ST_ENC_TAG : ST_DEC_TAG;
                        default  : next_state = ST_DONE;
                    endcase
                end else begin
                    next_state = ST_PERM;
                end
            end

            //==============================================================================
            // AD: Absorb AD blocks, then move to payload path (ENC->PT_IN, DEC->CT_IN).
            ST_AD: begin
                if (padded_tvalid_i && padded_tuser_i != TUSER_AD) begin
                    next_state = is_enc ? ST_PT_IN : ST_CT_IN;
                end else if (ad_word_valid && (padded_tlast_i || ad_word_r == 1'b1)) begin
                    next_state = ST_PERM;
                end else begin
                    next_state = ST_AD;
                end
            end

            //==============================================================================
            // PT_IN: Encrypt payload; final word goes to finalization setup.
            ST_PT_IN: begin
                if (pt_word_valid) begin
                    if (padded_tlast_i) next_state = ST_TAG_INIT;
                    else if (dat_word_r == 1'b1) next_state = ST_PERM;
                    else next_state = ST_PT_IN;
                end else begin
                    next_state = ST_PT_IN;
                end
            end

            //==============================================================================
            // CT_IN: Decrypt payload; final word goes to finalization setup.
            ST_CT_IN: begin
                if (padded_tvalid_i && m_axis_tready_i) begin
                    if (padded_tlast_i) begin
                        if (padded_tkeep_raw_i == 8'hFF) begin
                            // Full word, padding spills into next word/block
                            if (dat_word_r == 1'b1) next_state = ST_PERM;
                            else next_state = ST_CT_PAD_0;
                        end else begin
                            // Partial word, padding injected in current word
                            next_state = ST_TAG_INIT;
                        end
                    end
                    else if (dat_word_r == 1'b1) next_state = ST_PERM;
                    else next_state = ST_CT_IN;
                end else begin
                    next_state = ST_CT_IN;
                end
            end

            // CT_PAD_0: Inject 0x80 into S1 when CT ends on a full word 0.
            ST_CT_PAD_0: begin
                next_state = ST_TAG_INIT;
            end

            //==============================================================================
            // TAG_INIT: Perform pre-final-permutation key XOR steps.
            ST_TAG_INIT: begin
                if (tag_init_cnt_r == 2'd2) begin
                    next_state = ST_PERM;
                end else begin
                    next_state = ST_TAG_INIT;
                end
            end

            //==============================================================================
            // ENC_TAG: Stream out computed tag words S3 and S4.
            ST_ENC_TAG: begin
                if (m_axis_tvalid_o && m_axis_tready_i && tag_cnt_r == 1'b1) begin
                    next_state = ST_DONE;
                end else begin
                    next_state = ST_ENC_TAG;
                end
            end

            //==============================================================================
            // DEC_TAG: Receive two tag words before verification.
            ST_DEC_TAG: begin
                if (tag_cnt_r == 1'b1 && padded_tvalid_i && padded_tready_o && padded_tuser_i == TUSER_TAG) begin
                    next_state = ST_VERIFY;
                end else begin
                    next_state = ST_DEC_TAG;
                end
            end

            //==============================================================================
            // VERIFY: Compare received and computed tag words over two cycles.
            ST_VERIFY: begin
                if (verify_cnt_r == 2'd2) next_state = ST_DONE;
                else next_state = ST_VERIFY;
            end

            //==============================================================================
            // DONE: Hold completion flags until start_i deasserts.
            ST_DONE: begin
                if (!start_i) next_state = ST_IDLE;
                else next_state = ST_DONE;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    //==========================================================================
    // Output Decoder
    //==========================================================================

    always_comb begin
        busy_o             = 1'b1;
        done_o             = 1'b0;
        tag_fail_o         = 1'b0;
        start_perm_o       = 1'b0;
        round_config_o     = ROUND_PB;
        word_sel_o         = 3'd0;
        data_o             = 64'd0;
        write_en_o         = 1'b0;
        xor_en_o           = 1'b0;
        in_data_sel_o      = DATA_IN_AXI_SEL;
        padded_tready_o    = 1'b0;
        m_axis_tdata_o  = 64'd0;
        m_axis_tkeep_o  = 8'd0;
        m_axis_tuser_o  = TUSER_RESERVED;
        m_axis_tlast_o  = 1'b0;
        m_axis_tvalid_o = 1'b0;

        case (state_r)

            ST_IDLE: begin
                busy_o = 1'b0;
            end

            //==============================================================================
            /*
                INIT state:
                cnt=0: S0 <- IV <- 0x00001000808c0001
                cnt=1,2: S1,S2 <- K
                cnt=3,4: S3,S4 <- N
            */
            ST_INIT: begin
                if (init_cnt_r == 3'd0) begin
                    write_en_o     = lascon_ready_i;
                    xor_en_o       = 1'b0;
                    in_data_sel_o  = DATA_IN_AEAD_SEL;
                    word_sel_o     = 3'd0;
                    data_o         = AEAD128_IV;
                end else if (init_cnt_r <= 3'd2) begin
                    padded_tready_o = 1'b1;
                    if (padded_tvalid_i && padded_tuser_i == TUSER_KEY) begin
                        write_en_o     = 1'b1;
                        xor_en_o       = 1'b0;
                        in_data_sel_o  = DATA_IN_AXI_SEL;
                        word_sel_o     = init_cnt_r[2:0];
                    end
                end else begin
                    padded_tready_o = 1'b1;
                    if (padded_tvalid_i && padded_tuser_i == TUSER_NONCE) begin
                        write_en_o     = 1'b1;
                        xor_en_o       = 1'b0;
                        in_data_sel_o  = DATA_IN_AXI_SEL;
                        word_sel_o     = init_cnt_r[2:0];
                    end
                end
            end

            //==============================================================================
            /*
                ST_PERM - Shared Permutation State

                Reused across all four permutation phases (CTX_INIT, CTX_AD, CTX_DATA,
                CTX_FINAL). Internally executes three sequential sub-phases:

                Sub-phase 1 (!perm_started_r):
                Asserts start_perm_o for one cycle and drives round_config_o with the
                correct round count based on perm_ctx_r:
                CTX_INIT/FINAL -> ROUND_PA (12 rounds), CTX_AD/DATA -> ROUND_PB (8 rounds).

                Sub-phase 2 (waiting):
                Idles while ascon_core executes its permutation rounds. No outputs are
                driven. A one-cycle gap exists between perm_done and post_perm_active_r
                becoming active due to the registered nature of post_perm_active_r.

                Sub-phase 3 (post_perm_active_r):
                Performs post-permutation XOR writes into the state using post_perm_cnt_r:
                CTX_INIT_perm: XOR K into S3, S4
                CTX_AD_perm: XOR domain separation into S4
                CTX_FINAL_perm: XOR K into S3, S4
            */
            ST_PERM: begin
                if (!perm_started_r && !post_perm_active_r) begin
                    // Sub-phase 1: trigger permutation
                    start_perm_o   = 1'b1;
                    round_config_o = (perm_ctx_r == CTX_INIT || perm_ctx_r == CTX_FINAL)
                                        ? ROUND_PA : ROUND_PB;

                end else if (post_perm_active_r) begin
                    // Sub-phase 3: post-perm XOR writes into state
                    write_en_o    = 1'b1;
                    xor_en_o      = 1'b1;
                    in_data_sel_o = DATA_IN_AEAD_SEL;

                    case (perm_ctx_r)
                        CTX_INIT, CTX_FINAL: begin
                            // cnt=0: XOR K into S3
                            // cnt=1: XOR K into S4
                            word_sel_o = (post_perm_cnt_r == 2'd0) ? 3'd3 : 3'd4;
                            data_o     = (post_perm_cnt_r == 2'd0) ? key_r[0] : key_r[1];
                        end
                        CTX_AD: begin
                            // Domain separation: DSEP XOR into S4
                            word_sel_o = 3'd4;
                            data_o     = DSEP;
                        end
                        CTX_CT_PAD: begin
                            // Padding byte: 0x80 XOR into S0 MSB
                            word_sel_o = 3'd0;
                            data_o     = 64'h80000000_00000000;
                        end
                        default: ;
                    endcase
                end
            end

            // AD: XOR each AD word into S0 (word 0) or S1 (word 1).
            ST_AD: begin
                padded_tready_o = 1'b1;
                if (padded_tvalid_i && padded_tuser_i != TUSER_AD) begin
                    // Do not consume the first non-AD beat in ST_AD.
                    // Hold it for ST_PT_IN/ST_CT_IN after domain separation.
                    padded_tready_o = 1'b0;
                    // No AD present: apply domain separation once and proceed.
                    write_en_o    = 1'b1;
                    xor_en_o      = 1'b1;
                    in_data_sel_o = DATA_IN_AEAD_SEL;
                    word_sel_o    = 3'd4;
                    data_o        = DSEP;
                end else if (padded_tvalid_i && padded_tuser_i == TUSER_AD) begin
                    write_en_o    = 1'b1;
                    xor_en_o      = 1'b1;
                    in_data_sel_o = DATA_IN_AXI_SEL;
                    word_sel_o    = {2'b00, ad_word_r}; // 0=S0, 1=S1
                end
            end

            // PT_IN: XOR PT into state, simultaneously output CT.
            ST_PT_IN: begin
                // In ST_PT_IN, if it's a synthetic padding block (padded_is_padding_i == 1),
                // we absorb it into the state but DO NOT output it (CT length == PT length).
                // Wait, if m_axis_tready_i is 0, we can still write the state?
                // No, we must obey AXI flow control. If we aren't outputting, we don't strictly need m_axis_tready_i.
                // But it's safer to just condition m_axis_tvalid_o.
                padded_tready_o = padded_is_padding_i ? 1'b1 : m_axis_tready_i;
                if (padded_tvalid_i && padded_tready_o) begin
                    write_en_o      = 1'b1;
                    xor_en_o        = 1'b1;
                    in_data_sel_o   = DATA_IN_AXI_SEL;
                    word_sel_o      = {2'b00, dat_word_r};
                    m_axis_tdata_o  = core_data_i ^ padded_tdata_i;
                    m_axis_tvalid_o = ~padded_is_padding_i;
                    m_axis_tkeep_o  = padded_tkeep_raw_i; // Output raw TKEEP, not the overwritten FF
                    m_axis_tuser_o  = TUSER_CT;
                    m_axis_tlast_o  = padded_tlast_i;
                end
            end


            // CT_IN: Overwrite state with CT, simultaneously output PT.
            ST_CT_IN: begin
                padded_tready_o = m_axis_tready_i;
                if (padded_tvalid_i && m_axis_tready_i) begin
                    logic [63:0] ct_mask;
                    logic [63:0] pad_bit;
                    ct_mask = tkeep_to_mask(padded_tkeep_raw_i);
                    pad_bit = get_padding_bit(padded_tkeep_raw_i);

                    write_en_o      = 1'b1;
                    xor_en_o        = 1'b0; // We use direct overwrite because we manually compute the mixed value
                    in_data_sel_o   = DATA_IN_AEAD_SEL;
                    word_sel_o      = {2'b00, dat_word_r};

                    // State update: Valid bytes take CT. Invalid bytes keep State ^ 0x80 (padding).
                    data_o          = (padded_tdata_i & ct_mask) | ((core_data_i ^ pad_bit) & ~ct_mask);

                    m_axis_tdata_o  = core_data_i ^ padded_tdata_i;
                    m_axis_tvalid_o = 1'b1;
                    m_axis_tkeep_o  = padded_tkeep_raw_i;
                    m_axis_tuser_o  = TUSER_PT;
                    m_axis_tlast_o  = padded_tlast_i;
                end
            end

            // TAG_INIT: Pre-final-permutation key XOR.
            ST_TAG_INIT: begin
                if (tag_init_cnt_r < 2'd2) begin
                    write_en_o    = 1'b1;
                    xor_en_o      = 1'b1;
                    in_data_sel_o = DATA_IN_AEAD_SEL;
                    word_sel_o    = (tag_init_cnt_r == 2'd0) ? 3'd3 : 3'd4;
                    data_o        = (tag_init_cnt_r == 2'd0) ? key_r[0] : key_r[1];
                end
            end

            // ENC_TAG: Output computed tag words: S3 (cnt=0) then S4 (cnt=1).
            ST_ENC_TAG: begin
                m_axis_tvalid_o = 1'b1;
                m_axis_tkeep_o  = 8'hFF;
                m_axis_tuser_o  = TUSER_TAG;
                m_axis_tlast_o  = (tag_cnt_r == 1'b1);
                word_sel_o      = (tag_cnt_r == 1'b0) ? 3'd3 : 3'd4;
                m_axis_tdata_o  = core_data_i;
            end

            // DEC_TAG: Accept two incoming tag words for later comparison.
            ST_DEC_TAG: begin
                padded_tready_o = 1'b1;
            end

            // VERIFY: Drive word_sel to read S3 (cnt=0) then S4 (cnt=1).
            ST_VERIFY: begin
                word_sel_o = (verify_cnt_r == 2'd0) ? 3'd3 : 3'd4;
            end

            //============================================================================
            ST_DONE: begin
                busy_o     = 1'b0;
                done_o     = 1'b1;
                tag_fail_o = (is_enc ? 1'b0 : ~tag_ok_r);
            end

            default: ;
        endcase
    end

    //============================================================================
    // ACTION LOGIC
    //============================================================================

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            perm_ctx_r         <= CTX_INIT;
            init_cnt_r         <= 3'd0;
            perm_started_r     <= 1'b0;
            post_perm_active_r <= 1'b0;
            post_perm_cnt_r    <= 2'd0;
            ad_word_r          <= 1'b0;
            ad_last_seen_r     <= 1'b0;
            dat_word_r         <= 1'b0;
            dat_last_seen_r    <= 1'b0;
            tag_init_cnt_r     <= 2'd0;
            tag_cnt_r          <= 1'b0;
            verify_cnt_r       <= 2'd0;
            key_r[0]           <= 64'd0;
            key_r[1]           <= 64'd0;
            rx_tag_r[0]        <= 64'd0;
            rx_tag_r[1]        <= 64'd0;
            tag_ok_r           <= 1'b1;
        end else begin
            case (state_r)
                ST_IDLE: begin
                    if (start_i) begin
                        init_cnt_r         <= 3'd0;
                        perm_ctx_r         <= CTX_INIT;
                        ad_word_r          <= 1'b0;
                        ad_last_seen_r     <= 1'b0;
                        dat_word_r         <= 1'b0;
                        dat_last_seen_r    <= 1'b0;
                        tag_init_cnt_r     <= 2'd0;
                        tag_cnt_r          <= 1'b0;
                        verify_cnt_r       <= 2'd0;
                        tag_ok_r           <= 1'b1;
                        perm_started_r     <= 1'b0;
                        post_perm_active_r <= 1'b0;
                        post_perm_cnt_r    <= 2'd0;
                    end
                end

             // INIT counter + key capture
            ST_INIT: begin
                    case (init_cnt_r)
                        3'd0: begin
                            if (lascon_ready_i) init_cnt_r <= 3'd1;
                        end
                        3'd1: begin
                            if (phs && padded_tuser_i == TUSER_KEY) begin
                                key_r[0]   <= padded_tdata_i; // Capture K
                                init_cnt_r <= 3'd2;
                            end
                        end
                        3'd2: begin
                            if (phs && padded_tuser_i == TUSER_KEY) begin
                                key_r[1]   <= padded_tdata_i; // Capture K
                                init_cnt_r <= 3'd3;
                            end
                        end
                        3'd3: begin
                            if (phs && padded_tuser_i == TUSER_NONCE)
                                init_cnt_r <= 3'd4;
                        end
                        3'd4: ; // Hold; next-state transitions on this beat
                        default: ;
                    endcase
                end

                ST_PERM: begin
                    if (!perm_started_r && !post_perm_active_r)
                        perm_started_r <= 1'b1;

                    if (perm_done) begin
                        perm_started_r <= 1'b0;
                        if (needs_post_perm) begin
                            post_perm_active_r <= 1'b1;
                            post_perm_cnt_r    <= 2'd0;
                        end
                    end

                    if (post_perm_active_r) begin
                        if (pp_done)
                            post_perm_active_r <= 1'b0;
                        else
                            post_perm_cnt_r <= post_perm_cnt_r + 2'd1;
                    end
                end

                ST_AD: begin
                    if (padded_tvalid_i && padded_tuser_i != TUSER_AD) begin
                        ad_last_seen_r <= 1'b1;
                    end else if (phs && padded_tuser_i == TUSER_AD) begin
                        if (padded_tlast_i) begin
                            ad_last_seen_r <= 1'b1;
                            perm_ctx_r     <= CTX_AD; // This MUST be set, or it loops back to CTX_INIT!
                            ad_word_r      <= 1'b0;
                        end else if (ad_word_r == 1'b1) begin
                            // Intermediate block complete → trigger p^b
                            perm_ctx_r <= CTX_AD;
                            ad_word_r  <= 1'b0;
                        end else begin
                            ad_word_r <= 1'b1; // Word 0 → advance to word 1
                        end
                    end
                end

                // PT block word counter
                ST_PT_IN: begin
                    if (phs) begin
                        if (padded_tlast_i) begin
                            dat_last_seen_r <= 1'b1;
                            dat_word_r      <= 1'b0;
                        end else if (dat_word_r == 1'b1) begin
                            perm_ctx_r <= CTX_DATA;
                            dat_word_r <= 1'b0;
                        end else begin
                            dat_word_r <= 1'b1;
                        end
                    end
                end

                // CT block word counter
                ST_CT_IN: begin
                    if (phs) begin
                        if (padded_tlast_i) begin
                            dat_last_seen_r <= 1'b1;
                            dat_word_r      <= 1'b0;
                            if (padded_tkeep_raw_i == 8'hFF && dat_word_r == 1'b1) begin
                                perm_ctx_r <= CTX_CT_PAD;
                            end
                        end else if (dat_word_r == 1'b1) begin
                            perm_ctx_r <= CTX_DATA;
                            dat_word_r <= 1'b0;
                        end else begin
                            dat_word_r <= 1'b1;
                        end
                    end
                end

                ST_TAG_INIT: begin
                    if (tag_init_cnt_r < 2'd2)
                        tag_init_cnt_r <= tag_init_cnt_r + 2'd1;

                    if (tag_init_cnt_r == 2'd1)
                        perm_ctx_r <= CTX_FINAL;

                    if (tag_init_cnt_r == 2'd2)
                        tag_init_cnt_r <= 2'd0;
                end

                // Tag output counter
                ST_ENC_TAG: begin
                    if (m_axis_tvalid_o && m_axis_tready_i)
                        tag_cnt_r <= ~tag_cnt_r;
                end

                ST_DEC_TAG: begin
                    if (phs && padded_tuser_i == TUSER_TAG) begin
                        rx_tag_r[tag_cnt_r] <= padded_tdata_i;
                        tag_cnt_r           <= ~tag_cnt_r;
                    end
                end

                // Tag comparison
                ST_VERIFY: begin
                    case (verify_cnt_r)
                        2'd0: begin
                            if (core_data_i != rx_tag_r[0]) tag_ok_r <= 1'b0;
                            verify_cnt_r <= 2'd1;
                        end
                        2'd1: begin
                            if (core_data_i != rx_tag_r[1]) tag_ok_r <= 1'b0;
                            verify_cnt_r <= 2'd2;
                        end
                        default: ; // cnt=2: hold until state → ST_DONE
                    endcase
                end

                default: ;
            endcase
            end
        end

endmodule
