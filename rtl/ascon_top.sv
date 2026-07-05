/*
 * Module Name: ascon_top
 * Author(s): Kiet Le
 * Description:
 * Top-level wrapper and routing arbiter for the Ascon Cryptographic
 * Hardware Accelerator, supporting AEAD128, Hash256, XOF128, and CXOF128.
 *
 * Architecture Overview:
 * This design employs a "Decoupled Data/Control" strategy, strictly dividing
 * the cryptographic mathematics and bit-level formatting from the protocol-specific
 * state machines:
 *
 * 1. The "Pure" Ascon Core (The Muscle): A centralized, protocol-agnostic
 * module that solely maintains the 320-bit state and executes the
 * mathematical permutation rounds (p_C, p_S, p_L). It possesses no
 * knowledge of encryption, hashing rules, or padding.
 *
 * 2. The AXI-Stream Padder (The Framer): A pre-processor that intercepts
 * the raw incoming AXI stream. It abstracts away the complex Ascon sponge
 * padding rules and rate differences (64-bit vs 128-bit blocks), providing
 * a clean, rate-aligned `padded_tdata` stream to the internal logic.
 *
 * 3. Dedicated Sub-FSMs (The Brains): Protocol-specific controllers
 * (e.g., aead_fsm, hash_fsm) that manage AXI-Stream handshaking,
 * domain separation, and permutation scheduling. They operate strictly as
 * control-path orchestrators, unburdened by byte-level padding logic.
 *
 * 4. Top-Level Arbiter (This Module): Acts as a traffic director. Based
 * on the selected operating mode (mode_i), it multiplexes the core control
 * signals and AXI handshakes between the active Sub-FSM and the hardware.
 *
 * Datapath Logistics:
 * - INPUT: The raw `s_axis_tdata` is pre-processed by the padder. The formatted
 * `padded_tdata` is routed directly to the Core or top-level XOR via a mux,
 * keeping the high-speed data completely out of the FSMs.
 * - OUTPUT (Hash/XOF): During the squeeze phase, the Core's state output
 * (`core_data_o`) flows directly to the top-level AXI master (`m_axis_tdata`),
 * entirely bypassing the Hash FSM.
 * - OUTPUT (AEAD): The AEAD FSM and top-level XOR module tap into `core_data_o`
 * to externally compute Plaintext (resolving the decryption state-update
 * conflict) and verify the 128-bit MAC Tag.
 *
 * Interface Notes (Phase 1 Development):
 * High-speed payload data is streamed via standard AXI4-Stream interfaces.
 * Configuration and triggers are temporarily managed via discrete control
 * wires (mode_i, start_i, busy_o) to isolate and simplify datapath verification
 * before migrating to a standard memory-mapped AXI4-Lite CSR interface.
 *
 * Ref: NIST SP 800-232
 */

`timescale 1ns / 1ps

import ascon_pkg::*;

module ascon_top (
    // -----------------------------------------------------------------------
    // Global Clock and Reset
    // -----------------------------------------------------------------------
    input  logic                                clk,
    input  logic                                rst,

    // -----------------------------------------------------------------------
    // Basic Control & Status Interface
    // -----------------------------------------------------------------------
    input  ascon_mode_t                         mode_i,     // Operating mode selection (00: AEAD128, 01: Hash256, 10: XOF128, 11: CXOF128)
    input  logic [31:0]                         xof_len_i,  // 0 = Infinite/Continuous Mode, else specific byte length
    input  logic                                start_i,    // Pulse high to begin
    input  logic                                abort_i,    // Pulse high to terminate continuous squeezing
    output logic                                busy_o,     // High when FSM is active
    output logic                                done_o,     // Pulse high when complete
    output logic                                tag_fail_o, // High if AEAD decryption MAC check fails

    // -----------------------------------------------------------------------
    // AXI4-Stream Slave Interface (Data IN: Key, Nonce, AD, PT, CT)
    // -----------------------------------------------------------------------
    input  logic [WORD_WIDTH-1:0]               s_axis_tdata,  // Data input
    input  logic [(WORD_WIDTH/8)-1:0]           s_axis_tkeep,  // Byte enables for padding
    input  logic [TUSER_WIDTH-1:0]              s_axis_tuser,  // Packet type indicator
    input  logic                                s_axis_tlast,  // Boundary marker
    input  logic                                s_axis_tvalid, // Valid signal
    output logic                                s_axis_tready, // Tells master FSM is ready

    // -----------------------------------------------------------------------
    // AXI4-Stream Master Interface (Data OUT: CT, PT, Tag, Hash Digest)
    // -----------------------------------------------------------------------
    output logic [WORD_WIDTH-1:0]               m_axis_tdata,  // Data output
    output logic [(WORD_WIDTH/8)-1:0]           m_axis_tkeep,  // Byte enables for padding
    output logic [TUSER_WIDTH-1:0]              m_axis_tuser,  // Tells downstream if CT or Tag
    output logic                                m_axis_tlast,  // End of output stream
    output logic                                m_axis_tvalid, // Valid signal
    input  logic                                m_axis_tready  // Tells master FSM is ready
);
    // =========================================================================
    // Logic Instantiations
    // =========================================================================

    // --- Ascon Core Signals ---
    logic           core_start_perm_i;
    logic           core_round_config_i;
    logic   [2:0]   core_word_sel_i;
    ascon_word_t    core_data_i;
    logic           core_write_en_i;
    ascon_word_t    core_data_o;
    logic           core_ready_o;
    data_sel_t      core_in_data_sel;

    // --- Arbiter Muxing FSM Logic ---
    // We define internal wires coming OUT of the sub-FSMs
    logic           aead_write_en, hash_write_en;
    logic [2:0]     aead_word_sel, hash_word_sel;
    logic           aead_start_perm, hash_start_perm;
    logic           aead_round_config, hash_round_config;
    ascon_word_t    aead_data_o, hash_data_o;
    xor_sel_t       aead_xor_sel, hash_xor_sel;
    data_sel_t      aead_in_data_sel, hash_in_data_sel;

    // AEAD specific intermediate mapping
    logic           aead_xor_en;
    data_sel_t      aead_in_data_sel_raw;

    always_comb begin
        if (aead_xor_en) begin
            aead_in_data_sel = DATA_IN_XOR_SEL;
            aead_xor_sel     = (aead_in_data_sel_raw == DATA_IN_AXI_SEL) ? XOR_IN_AXI_SEL : XOR_IN_AEAD_SEL;
        end else begin
            aead_in_data_sel = aead_in_data_sel_raw;
            aead_xor_sel     = XOR_IN_AEAD_SEL;
        end
    end

    // --- XOR Module Signals ---
    ascon_word_t    xor_op1, xor_op2, xor_res;
    xor_sel_t       xor_in_op2_sel;

    // --- Padder Interconnect Wires ---
    // These carry the formatted stream from the padder to the internal logic
    ascon_word_t    padded_tdata;
    logic [7:0]     padded_tkeep;
    axi_tuser_t     padded_tuser;
    logic           padded_tlast;
    logic           padded_tvalid;
    logic           padded_is_padding;
    logic [7:0]     padded_tkeep_raw;
    logic           padded_tready; // Driven by the Arbiter Mux, read by the Padder

    // --- AEAD FSM Intermediate Outputs ---
    logic           aead_busy, aead_done, aead_tag_fail;
    logic           aead_s_axis_tready;
    logic [63:0]    aead_m_axis_tdata;
    logic [7:0]     aead_m_axis_tkeep;
    axi_tuser_t     aead_m_axis_tuser;
    logic           aead_m_axis_tlast;
    logic           aead_m_axis_tvalid;

    // --- Hash FSM Intermediate Outputs ---
    logic           hash_busy, hash_done;
    logic           hash_s_axis_tready;
    logic [63:0]    hash_m_axis_tdata;
    logic [7:0]     hash_m_axis_tkeep;
    axi_tuser_t     hash_m_axis_tuser;
    logic           hash_m_axis_tlast;
    logic           hash_m_axis_tvalid;

    // --- Helper: Big-Endian to Little-Endian Output Swap ---
    function automatic ascon_word_t swap_bytes(input ascon_word_t data);
        return {data[7:0],   data[15:8],  data[23:16], data[31:24],
                data[39:32], data[47:40], data[55:48], data[63:56]};
    endfunction

    // =======================================================================
    // INTERNAL ARCHITECTURE & INSTANTIATIONS
    // =======================================================================

    // 1. Controller FSM
    // Your state machine that monitors `start_i` and `mode_i`.
    // It asserts `s_axis_tready` to pull data in, decodes `s_axis_tuser` to
    // know what the data is, and applies Ascon padding using `s_axis_tkeep`
    // when `s_axis_tlast` goes high.

    // --- AXI4-Stream Pre-processor (Padder) ---
    ascon_padder u_padder (
        .clk            (clk),
        .rst            (rst),
        .mode_i         (mode_i),

        // Raw Input from Outside World (Directly connected to top-level ports)
        .s_axis_tdata_i     (s_axis_tdata),
        .s_axis_tkeep_i     (s_axis_tkeep),
        .s_axis_tuser_i     (axi_tuser_t'(s_axis_tuser)),
        .s_axis_tlast_i     (s_axis_tlast),
        .s_axis_tvalid_i    (s_axis_tvalid),
        .s_axis_tready_o    (s_axis_tready), // Padder controls the real AXI flow

        // Formatted Output to Internal Logic
        .padded_tdata_o     (padded_tdata),
        .padded_tkeep_o     (padded_tkeep),
        .padded_tuser_o     (padded_tuser),
        .padded_tlast_o     (padded_tlast),
        .padded_tvalid_o    (padded_tvalid),
        .padded_is_padding_o(padded_is_padding),
        .padded_tkeep_raw_o (padded_tkeep_raw),
        .padded_tready_i    (padded_tready)  // Driven by the active FSM via the Arbiter
    );

    // The Top Level Mux directly feeds the Core based on the Mode
    always_comb begin
        // AEAD Functions
        if (mode_i == MODE_AEAD_ENC || mode_i == MODE_AEAD_DEC) begin
            // Core Control Muxing
            core_start_perm_i   = aead_start_perm;
            core_round_config_i = aead_round_config;
            core_word_sel_i     = aead_word_sel;
            core_write_en_i     = aead_write_en;
            core_in_data_sel    = aead_in_data_sel;
            xor_in_op2_sel      = aead_xor_sel;

            // AXI Stream Handshake Muxing
            padded_tready       = aead_s_axis_tready;
            m_axis_tdata        = aead_m_axis_tvalid ? swap_bytes(aead_m_axis_tdata) : 64'b0;
            m_axis_tvalid       = aead_m_axis_tvalid;
            m_axis_tlast        = aead_m_axis_tlast;
            m_axis_tuser        = aead_m_axis_tuser;
            m_axis_tkeep        = aead_m_axis_tkeep;

        // HASH/XOF Functions
        end else begin
            // Core Control Muxing
            core_start_perm_i   = hash_start_perm;
            core_round_config_i = hash_round_config;
            core_word_sel_i     = hash_word_sel;
            core_write_en_i     = hash_write_en;
            core_in_data_sel    = hash_in_data_sel;
            xor_in_op2_sel      = hash_xor_sel;

            // AXI Stream Handshake Muxing
            padded_tready       = hash_s_axis_tready;

            // Swap the Big-Endian core output back to Little-Endian for the AXI Master
            // Security: Don't broadcast garbage data when not valid
            m_axis_tdata        = hash_m_axis_tvalid ? swap_bytes(core_data_o) : 64'b0;

            m_axis_tvalid       = hash_m_axis_tvalid;
            m_axis_tlast        = hash_m_axis_tlast;
            m_axis_tuser        = hash_m_axis_tuser;
            m_axis_tkeep        = hash_m_axis_tkeep;
        end
    end

    // --- AEAD FSM ---
    aead_fsm u_aead_fsm (
        .clk             (clk),
        .rst             (rst),

        // AEAD FSM Control I/O
        .mode_i          (mode_i),
        .start_i         (start_i),           // Direct from top-level
        .busy_o          (aead_busy),         // Intermediate wire for muxing
        .done_o          (aead_done),         // Intermediate wire for muxing
        .tag_fail_o      (aead_tag_fail),     // Intermediate wire for muxing

        // Ascon Control I/O
        .ascon_ready_i   (core_ready_o),
        .start_perm_o    (aead_start_perm),
        .round_config_o  (aead_round_config),
        .word_sel_o      (aead_word_sel),
        .data_o          (aead_data_o),
        .write_en_o      (aead_write_en),
        .xor_en_o        (aead_xor_en),
        .in_data_sel_o   (aead_in_data_sel_raw),
        .core_data_i     (core_data_o),       // Read state from core for Decryption/Tag

        // --- AXI4-Stream Slave (Data coming IN) ---
        .padded_tdata_i  (padded_tdata),     // Direct from padder
        .padded_tkeep_i  (padded_tkeep),     // Direct from padder
        .padded_tuser_i  (padded_tuser),     // Direct from padder
        .padded_tlast_i  (padded_tlast),     // Direct from padder
        .padded_tvalid_i (padded_tvalid),    // Direct from padder
        .padded_is_padding_i(padded_is_padding), // Direct from padder
        .padded_tkeep_raw_i (padded_tkeep_raw),  // Direct from padder
        .padded_tready_o (aead_s_axis_tready), // Intermediate wire for muxing

        // --- AXI4-Stream Master (Data going OUT) ---
        .m_axis_tdata_o  (aead_m_axis_tdata),  // Intermediate wire for muxing
        .m_axis_tkeep_o  (aead_m_axis_tkeep),  // Intermediate wire for muxing
        .m_axis_tuser_o  (aead_m_axis_tuser),  // Intermediate wire for muxing
        .m_axis_tlast_o  (aead_m_axis_tlast),  // Intermediate wire for muxing
        .m_axis_tvalid_o (aead_m_axis_tvalid), // Intermediate wire for muxing
        .m_axis_tready_i (m_axis_tready)       // Direct from top-level
    );


    hash_fsm u_hash_fsm (
        .clk                    (clk),
        .rst                    (rst),

        // Hash FSM Control I/O
        .mode_i                 (mode_i),
        .xof_len_i              (xof_len_i),         // Requested output length for XOF/CXOF (e.g., 32 bits)
        .start_i                (start_i),           // Direct from top-level
        .abort_i                (abort_i),           // Pulse high to terminate continuous squeezing
        .busy_o                 (hash_busy),         // Intermediate wire for muxing
        .done_o                 (hash_done),         // Intermediate wire for muxing
        // Note: No tag_fail_o needed for Hash/XOF operations

        // Ascon Control I/O
        .ascon_ready_i          (core_ready_o),
        .start_perm_o           (hash_start_perm),
        .round_config_o         (hash_round_config),
        .word_sel_o             (hash_word_sel),
        .data_o                 (hash_data_o),       // Used to write the pre-computed Hash IVs into the core
        .write_en_o             (hash_write_en),
        .core_in_data_sel_o     (hash_in_data_sel),
        .xor_sel_o              (hash_xor_sel),

        // --- Padded AXI4-Stream Slave (Data coming FROM the Padder) ---
        .padded_tuser_i         (padded_tuser),     // Tells FSM if it's Message (M) or Custom String (Z)
        .padded_tlast_i         (padded_tlast),     // Trigger to run the permutation!
        .padded_tvalid_i        (padded_tvalid),
        .padded_tready_o        (hash_s_axis_tready),

        // --- AXI4-Stream Master (Data going OUT) ---
        .m_axis_tkeep_o         (hash_m_axis_tkeep),  // Intermediate wire for muxing (Will be 8'hFF mostly)
        .m_axis_tuser_o         (hash_m_axis_tuser),  // Intermediate wire for muxing (Set to TUSER_DIGEST)
        .m_axis_tlast_o         (hash_m_axis_tlast),  // Intermediate wire for muxing
        .m_axis_tvalid_o        (hash_m_axis_tvalid), // Intermediate wire for muxing
        .m_axis_tready_i        (m_axis_tready)       // Direct from top-level
    );

    // --- XOR Unit ---
    xor64 u_xor64 (
        .op1_i  (xor_op1),
        .op2_i  (xor_op2),
        .res_o  (xor_res)
    );
    assign xor_op1 = core_data_o;
    always_comb begin
        case(xor_in_op2_sel)
            XOR_IN_AEAD_SEL : xor_op2 = aead_data_o;
            XOR_IN_HASH_SEL : xor_op2 = hash_data_o;
            XOR_IN_AXI_SEL  : xor_op2 = padded_tdata;
            default         : xor_op2 = 64'd0;
        endcase
    end

    // --- Ascon Core ---
    ascon_core u_core (
        .clk            (clk),
        .rst            (rst),
        .start_perm_i   (core_start_perm_i),
        .round_config_i (core_round_config_i),
        .word_sel_i     (core_word_sel_i),
        .data_i         (core_data_i),
        .write_en_i     (core_write_en_i),
        .data_o         (core_data_o),
        .ready_o        (core_ready_o)
    );
    // Select Data Input
    always_comb begin
        case(core_in_data_sel)
            DATA_IN_AEAD_SEL : core_data_i = aead_data_o;
            DATA_IN_HASH_SEL : core_data_i = hash_data_o;
            DATA_IN_AXI_SEL  : core_data_i = padded_tdata;
            DATA_IN_XOR_SEL  : core_data_i = xor_res;
            default          : core_data_i = 64'd0;
        endcase
    end

    // =========================================================================
    // Top-Level Status Routing
    // =========================================================================
    always_comb begin
        if (mode_i == MODE_AEAD_ENC || mode_i == MODE_AEAD_DEC) begin
            busy_o     = aead_busy;
            done_o     = aead_done;
            tag_fail_o = aead_tag_fail;
        end else begin
            busy_o     = hash_busy;
            done_o     = hash_done;
            tag_fail_o = 1'b0; // Hash/XOF never fails a MAC check
        end
    end

endmodule
