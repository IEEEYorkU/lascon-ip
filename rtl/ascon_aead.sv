/* Module Name: ascon_aead
 * Author(s):  Rayhaan Yaser Mohammed, Tommy
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
 *   within a single clock cycle.
 * - Tag Verification: During decryption, the received tag words are latched in
 *   ST_DEC_TAG and compared against the computed tag words (S3, S4) in
 *   ST_VERIFY over two consecutive cycles using the combinational read port
 *   of ascon_core.
 *
 * Ref: NIST SP 800-232, Section 4
 */


import ascon_pkg::*;


module ascon_aead(
    //Clock, reset
    input logic clk,
    input logic rst,
//==========================================================================
    //Mode,Control
//==========================================================================

    input ascon_mode_t mode_i,  //Mode: ENC or DEC
    input logic        start_i,
    output logic       busy_o,
    output logic       done_o,
    output logic       tag_fail_o, //Decryption tag check fails

    //Interface
    input  logic                ascon_ready_i,
    output logic                start_perm_o,
    output logic                round_config_o,
    output logic     [2:0]      word_sel_o,  // target state word address S0,S1,.., S4
    output ascon_word_t         data_o,
    output logic                write_en_o,    output logic                write_en_o,
    output data_sel_t           in_data_sel_o,  //Mux select for core data_i source

    // AD- AXI STREAM from padder unit
    input ascon_word_t     padded_tdata_i, //Pre-processed
    input logic [7:0]      padded_tkeep_i, //Pass - through for CT
    input logic            padded_tlast_i, //last word in the message
    output logic            padded_tready_o,

    // Plaintext / Ciphertext - AX4 stream from padder unit
    output ascon_word_t     m_axis_tdata_o,
    output logic [2:0]      m_axis_tuser_o,
    output logic            m_axis_tlast_o,
    output logic            m_axis_tvalid_o,



    // Plaintext / Ciphertext - AX4 stream from padder unit
    output ascon_word_t     m_axis_tdata_o,
    output logic [7:0]      m_axis_tkeep_o,
    output logic [2:0]      m_axis_tuser_o,
    output logic            m_axis_tlast_o,
    output logic            m_axis_tvalid_o,
    input logic             m_axis_tready_i
);

    localparam ascon_word_t AEAD128_IV = 64'h00001000808c0001; // IV <-  0x00001000808c0001
    localparam ascon_word_t DSEP       = 64'h0000000000000001; // Domain separation: S ← S ⊕ (0^319 ∥ 1), only s4 change, s0,s1,s2,s3 are full of 0
    localparam logic ROUND_PA = 1'b1;  //12 round permutaiton
    localparam logic ROUND_PB = 1'b0;  //8 round permuation


    typedef enum logic [3:0] {
        ST_IDLE     = 4'd0,
        ST_INIT     = 4'd1,
        ST_PERM     = 4'd2,
        ST_AD       = 4'd3,
        ST_PT_IN    = 4'd4,
        ST_CT_IN    = 4'd5,
        ST_TAG_INIT = 4'd6,
        ST_ENC_TAG  = 4'd7,
        ST_DEC_TAG  = 4'd8,
        ST_VERIFY   = 4'd9,
        ST_DONE     = 4'd10
        //ST_ERROR    = 4'd11
    } state_t;

    typedef enum logic [1:0] {
        CTX_INIT  = 2'd0, //12 round permutation after initialization loading
        CTX_AD    = 2'd1, // 8 round permutation after each AD BLock
        CTX_DATA  = 2'd2, // 8 round permutation after each non-final PT/Ct block
        CTX_FINAL = 2'd3  // 8 round permutation during finalization
    } perm_ctx_t;

//==========================================================================
    // Register
//==========================================================================

    state_t    state_r;
    perm_ctx_t perm_ctx_r;

    //INIT Phase: tracks which word is being loaded into the core
    logic [2:0] init_cnt_r;

    //PERM phase management
    logic        perm_started_r;
    logic        post_perm_active_r;
    logic [1:0]  post_perm_cnt_r;

    //AD absorption
    logic    ad_word_r;
    logic    ad_last_seen_r;

    //PT/CT absorption
    logic    dat_word_r;

    //Finalization
    logic [1:0] tag_init_cnt_r; //0=K->S3 XOR, 1=K->S4 XOR, 2=transition to PERM

    //Tag output(enc) and tag receive (dexc)
    logic tag_cnt_r;  //0=S3/T_word0, 1=S4/T_word1

    // Tag verification
    logic [1:0] verify_cnt_r;  // 0=compare S3, 1=compare S4, 2=done

    // Stored key captured during INIT
    ascon_word_t key_r[0:1];

    //dec only: received tag words
    ascon_word_t rx_tag_r[0:1];

    //tag match result
    logic tag_ok_r;
//==========================================================================
    //Combinational Helpers
//==========================================================================

    logic is_enc;
    assign is_enc = (mode_i == MODE_AEAD_ENC);

    //Permutation complete
    logic perm_done;
    assign perm_done = perm_started_r && ascon_ready_i;

    //Max post-per counter value
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
    assign needs_post_perm = (perm_ctx_r == CTX_INIT)  ||
                             (perm_ctx_r == CTX_FINAL)  ||
                             (perm_ctx_r == CTX_AD && ad_last_seen_r);



//==========================================================================
    // Sequential - FSM transitions and register latching
//==========================================================================

    state_t next_state;
    always_ff @(posedge clk or posedge rst) begin
        if(rst) state_r <= ST_IDLE;
        else state_r <=  next_state;
    end

//==========================================================================
    // NEXT-STATE Logic
//==========================================================================

    logic init_ack;
    assign init_ack = (state_r == ST_INIT) &&
                      ((init_cnt_r == 3'd0 && ascon_ready_i) ||
                       ((init_cnt_r <= 3'd2) && padded_tvalid_i && padded_tuser_i == TUSER_KEY && padded_tready_o) ||
                       ((init_cnt_r >= 3'd3 && init_cnt_r <= 3'd4) && padded_tvalid_i && padded_tuser_i == TUSER_NONCE && padded_tready_o));

    logic ad_word_valid;
    assign ad_word_valid = (state_r == ST_AD && padded_tvalid_i && padded_tuser_i == TUSER_AD && padded_tready_o);

    logic pt_word_valid;
    assign pt_word_valid = (state_r == ST_PT_IN && padded_tvalid_i && m_axis_tready_i);

    logic ct_word_valid;
    assign ct_word_valid = (state_r == ST_CT_IN && padded_tvalid_i && m_axis_tready_i);

    always_comb begin
        next_state = state_r;

        case (state_r)
            ST_IDLE: begin
                if (start_i) next_state = ST_INIT;
            end

            ST_INIT: begin
                if (init_cnt_r == 3'd4 && init_ack) begin
                    next_state = ST_PERM;
                end else begin
                    next_state = ST_INIT;
                end
            end

            ST_PERM: begin
                if (perm_done && (!needs_post_perm || pp_done)) begin
                    case (perm_ctx_r)
                        CTX_INIT : next_state = ST_AD;
                        CTX_AD   : next_state = is_enc ? ST_PT_IN : ST_CT_IN;
                        CTX_DATA : next_state = is_enc ? ST_PT_IN : ST_CT_IN;
                        CTX_FINAL: next_state = is_enc ? ST_ENC_TAG : ST_DEC_TAG;
                        default  : next_state = ST_DONE;
                    endcase
                end else begin
                    next_state = ST_PERM;
                end
            end

            ST_AD: begin
                if (padded_tvalid_i && padded_tuser_i != TUSER_AD) begin
                    next_state = is_enc ? ST_PT_IN : ST_CT_IN;
                end else if (ad_word_valid && padded_tlast_i) begin
                    next_state = ST_PERM;
                end else begin
                    next_state = ST_AD;
                end
            end

            ST_PT_IN: begin
                if (pt_word_valid) begin
                    if (padded_tlast_i) next_state = ST_TAG_INIT;
                    else next_state = ST_PERM;
                end else begin
                    next_state = ST_PT_IN;
                end
            end

            ST_CT_IN: begin
                if (ct_word_valid) begin
                    if (padded_tlast_i) next_state = ST_TAG_INIT;
                    else next_state = ST_PERM;
                end else begin
                    next_state = ST_CT_IN;
                end
            end

            ST_TAG_INIT: begin
                if (tag_init_cnt_r == 2'd2) begin
                    next_state = ST_PERM;
                end else begin
                    next_state = ST_TAG_INIT;
                end
            end

            ST_ENC_TAG: begin
                if (m_axis_tvalid_o && m_axis_tready_i && tag_cnt_r == 1'b1) begin
                    next_state = ST_DONE;
                end else begin
                    next_state = ST_ENC_TAG;
                end
            end

            ST_DEC_TAG: begin
                if (tag_cnt_r == 1'b1 && padded_tvalid_i && padded_tready_o && padded_tuser_i == TUSER_TAG) begin
                    next_state = ST_VERIFY;
                end else begin
                    next_state = ST_DEC_TAG;
                end
            end

            ST_VERIFY: begin
                if (verify_cnt_r == 2'd2) next_state = ST_DONE;
                else next_state = ST_VERIFY;
            end

            ST_DONE: begin
                if (!start_i) next_state = ST_IDLE;
                else next_state = ST_DONE;
            end

            default: next_state = ST_IDLE;
        endcase
    end


    //==========================================================================
    // Sequential side registers/control signals
    //==========================================================================

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            init_cnt_r         <= 3'd0;
            perm_ctx_r         <= CTX_INIT;
            perm_started_r     <= 1'b0;
            post_perm_active_r <= 1'b0;
            post_perm_cnt_r    <= 2'd0;
            ad_word_r          <= 1'b0;
            ad_last_seen_r     <= 1'b0;
            dat_word_r         <= 1'b0;
            tag_init_cnt_r     <= 2'd0;
            tag_cnt_r          <= 1'b0;
            verify_cnt_r       <= 2'd0;
            tag_ok_r           <= 1'b1;
            key_r[0]           <= 64'd0;
            key_r[1]           <= 64'd0;
            rx_tag_r[0]        <= 64'd0;
            rx_tag_r[1]        <= 64'd0;
        end else begin
            // INIT counter + key capture
            if (state_r == ST_INIT) begin
                if (init_cnt_r == 3'd0 && ascon_ready_i) begin
                    init_cnt_r <= 3'd1;
                end else if ((init_cnt_r <= 3'd2) && padded_tvalid_i && padded_tuser_i == TUSER_KEY && padded_tready_o) begin
                    init_cnt_r <= init_cnt_r + 3'd1;
                    key_r[init_cnt_r-1] <= padded_tdata_i;
                end else if ((init_cnt_r >= 3'd3 && init_cnt_r <= 3'd4) && padded_tvalid_i && padded_tuser_i == TUSER_NONCE && padded_tready_o) begin
                    init_cnt_r <= init_cnt_r + 3'd1;
                end
            end else if (next_state == ST_INIT) begin
                init_cnt_r <= 3'd0;
            end

            // PERM context set on entry
            if (state_r != ST_PERM && next_state == ST_PERM) begin
                case (state_r)
                    ST_INIT:  perm_ctx_r <= CTX_INIT;
                    ST_AD:    perm_ctx_r <= CTX_AD;
                    ST_PT_IN: perm_ctx_r <= CTX_DATA;
                    ST_CT_IN: perm_ctx_r <= CTX_DATA;
                    ST_TAG_INIT: perm_ctx_r <= CTX_FINAL;
                    default: perm_ctx_r <= perm_ctx_r;
                endcase
                perm_started_r <= 1'b0;
                post_perm_active_r <= 1'b0;
                post_perm_cnt_r <= 2'd0;
            end

            // Permutation sequencing
            if (state_r == ST_PERM) begin
                if (!perm_started_r) begin
                    perm_started_r <= 1'b1;
                end else if (perm_done && needs_post_perm && !post_perm_active_r) begin
                    post_perm_active_r <= 1'b1;
                    post_perm_cnt_r <= 2'd0;
                end else if (post_perm_active_r) begin
                    if (post_perm_cnt_r < pp_max) begin
                        post_perm_cnt_r <= post_perm_cnt_r + 2'd1;
                    end else begin
                        post_perm_active_r <= 1'b0;
                    end
                end
            end

            // AD state controls
            if (state_r == ST_AD && ad_word_valid) begin
                ad_word_r <= ~ad_word_r;
                ad_last_seen_r <= padded_tlast_i;
            end else if (next_state == ST_AD) begin
                ad_word_r <= 1'b0;
                ad_last_seen_r <= 1'b0;
            end

            // PT/CT word pointer
            if ((state_r == ST_PT_IN && pt_word_valid) || (state_r == ST_CT_IN && ct_word_valid)) begin
                dat_word_r <= ~dat_word_r;
            end else if (next_state == ST_PT_IN || next_state == ST_CT_IN) begin
                dat_word_r <= 1'b0;
            end

            // TAG init counter
            if (state_r == ST_TAG_INIT) begin
                if (tag_init_cnt_r < 2'd2) tag_init_cnt_r <= tag_init_cnt_r + 2'd1;
            end else if (next_state == ST_TAG_INIT) begin
                tag_init_cnt_r <= 2'd0;
            end

            // ENC_TAG counter
            if (state_r == ST_ENC_TAG && m_axis_tvalid_o && m_axis_tready_i) begin
                tag_cnt_r <= tag_cnt_r + 1'b1;
            end else if (next_state == ST_ENC_TAG) begin
                tag_cnt_r <= 1'b0;
            end

            // DEC_TAG receive
            if (state_r == ST_DEC_TAG && padded_tvalid_i && padded_tready_o && padded_tuser_i == TUSER_TAG) begin
                rx_tag_r[tag_cnt_r] <= padded_tdata_i;
                tag_cnt_r <= tag_cnt_r + 1'b1;
            end else if (next_state == ST_DEC_TAG) begin
                tag_cnt_r <= 1'b0;
            end

            // VERIFY phase
            if (state_r == ST_VERIFY) begin
                if (verify_cnt_r < 2'd2) begin
                    verify_cnt_r <= verify_cnt_r + 2'd1;
                end
                if (verify_cnt_r == 2'd0) begin
                    tag_ok_r <= (core_data_i == rx_tag_r[0]);
                end else if (verify_cnt_r == 2'd1) begin
                    tag_ok_r <= tag_ok_r && (core_data_i == rx_tag_r[1]);
                end
            end else if (next_state == ST_VERIFY) begin
                verify_cnt_r <= 2'd0;
                tag_ok_r <= 1'b1;
            end

            // DONE
            if (state_r == ST_DONE && !start_i) begin
                // clear non-state sequencers here if needed
            end

            // Reset perm_started and post_perm if exited PERM
            if (state_r == ST_PERM && next_state != ST_PERM) begin
                perm_started_r <= 1'b0;
                post_perm_active_r <= 1'b0;
                post_perm_cnt_r <= 2'd0;
            end
        end
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
        m_axis_tkeep_o  = 8'hFF;
        m_axis_tuser_o  = 3'd0;
        m_axis_tlast_o  = 1'b0;
        m_axis_tvalid_o = 1'b0;

        case (state_r)

            ST_IDLE: begin
                busy_o = 1'b0;
        end
//==============================================================================
        /*INIT state:
        cnt=0: S0 <- IV <- 0x00001000808c0001
        cnt=1,2: S1,S2 <- K
        cnt=3,4: S3,S4 <- N
        */

        ST_INIT: begin
            if(init_cnt_r == 3'd0) begin
                write_en_o     = ascon_ready_i;
                xor_en_o       = 1'b0;
                in_data_sel_o  = DATA_IN_AEAD_SEL;
                word_sel_o     = 3'd0;
                data_o         = AEAD128_IV;
            end

            else if (init_cnt_r <= 3'd2) begin
                padded_tready_o = 1'b1;
                if(padded_tvalid_i && padded_tuser_i == TUSER_KEY) begin
                    write_en_o     = 1'b1;
                    xor_en_o       = 1'b0;
                    in_data_sel_o  = DATA_IN_AXI_SEL;
                    word_sel_o     = init_cnt_r[2:0];
                end
            end

            else begin
                padded_tready_o = 1'b1;
                if(padded_tvalid_i && padded_tuser_i == TUSER_NONCE) begin
                    write_en_o     = 1'b1;
                    xor_en_o       = 1'b0;
                    in_data_sel_o  = DATA_IN_AXI_SEL;
                    word_sel_o     = init_cnt_r[2:0];
                end
            end
        end
//==============================================================================
   /*
   ST_PERM — Shared Permutation State

   Reused across all four permutation phases (CTX_INIT, CTX_AD, CTX_DATA,
   CTX_FINAL). Internally executes three sequential sub-phases:

   Sub-phase 1 (!perm_started_r):
   Asserts start_perm_o for one cycle and drives round_config_o with the
   correct round count based on perm_ctx_r:
   CTX_INIT/FINAL → ROUND_PA (12 rounds), CTX_AD/DATA → ROUND_PB (8 rounds).

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
                if ( !perm_started_r) begin
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
                            // cnt=0:  XOR K into S3
                            // cnt=1:  XOR K into S4
                            word_sel_o = (post_perm_cnt_r == 2'd0) ? 3'd3 : 3'd4;
                            data_o     = (post_perm_cnt_r == 2'd0) ? key_r[0] : key_r[1];
                        end
                        CTX_AD: begin
                            // Domain separation: DSEP XOR into S4
                            word_sel_o = 3'd4;
                            data_o     = DSEP;
                        end
                        default: ;
                    endcase
                end
            end

//============================================================================
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
                    word_sel_o    = {2'b00, ad_word_r}; //0=S0, 1=S1
                end
            end

//============================================================================
            // PT_IN: XOR PT into state, simultaneously output CT.
            ST_PT_IN: begin
                padded_tready_o = m_axis_tready_i;
                if (padded_tvalid_i && m_axis_tready_i) begin
                    write_en_o      = 1'b1;
                    xor_en_o        = 1'b1;
                    in_data_sel_o   = DATA_IN_AXI_SEL;
                    word_sel_o      = {2'b00, dat_word_r};
                    m_axis_tdata_o  = core_data_i ^ padded_tdata_i;
                    m_axis_tvalid_o = 1'b1;
                    m_axis_tkeep_o  = padded_tkeep_i;
                    m_axis_tuser_o  = 3'(TUSER_CT);
                    m_axis_tlast_o  = padded_tlast_i;
                end
            end
//============================================================================
            //CT_IN: Overwrite state with CT, simultaneously output PT.
            ST_CT_IN: begin
                padded_tready_o = m_axis_tready_i;
                if (padded_tvalid_i && m_axis_tready_i) begin
                    write_en_o      = 1'b1;
                    xor_en_o        = 1'b0;
                    in_data_sel_o   = DATA_IN_AXI_SEL;
                    word_sel_o      = {2'b00, dat_word_r};
                    m_axis_tdata_o  = core_data_i ^ padded_tdata_i;
                    m_axis_tvalid_o = 1'b1;
                    m_axis_tkeep_o  = padded_tkeep_i;
                    m_axis_tuser_o  = 3'(TUSER_PT);
                    m_axis_tlast_o  = padded_tlast_i;
                end
            end

//============================================================================
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

//============================================================================
            // ENC_TAG: Output computed tag words: S3 (cnt=0) then S4 (cnt=1).
            ST_ENC_TAG: begin
                m_axis_tvalid_o = 1'b1;
                m_axis_tkeep_o  = 8'hFF;
                m_axis_tuser_o  = 3'(TUSER_TAG);
                m_axis_tlast_o  = (tag_cnt_r == 1'b1);
                word_sel_o      = (tag_cnt_r == 1'b0) ? 3'd3 : 3'd4;
                m_axis_tdata_o  = core_data_i;
            end

//============================================================================
            // DEC_TAG: Accept two incoming tag words for later comparison.
            ST_DEC_TAG: begin
                padded_tready_o = 1'b1;
            end

//============================================================================
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
    end






endmodule
