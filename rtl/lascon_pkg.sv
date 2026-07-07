/*
 * Package Name: lascon_pkg
 * Description: Type definitions and constants for the Lascon Hardware Accelerator
 * Ref: NIST SP 800-232
 */

`timescale 1ns / 1ps

package lascon_pkg;

    // -------------------------------------------------------------------------
    // 1. Parameters (Constants)
    // -------------------------------------------------------------------------
    localparam int WORD_WIDTH   = 64;   // Ascon uses 64-bit words
    localparam int NUM_WORDS    = 5;    // State consists of S0..S4
    localparam int STATE_WIDTH  = 320;  // Total state size
    localparam int TUSER_WIDTH  = 4;    // Width of AXI4-Stream TUSER

    // -------------------------------------------------------------------------
    // 2. Type Definitions
    // -------------------------------------------------------------------------

    // A single 64-bit word (S0, S1, etc.)
    typedef logic [WORD_WIDTH-1:0] ascon_word_t;

    // The full Ascon state: 5 words of 64 bits each
    // Defined as [4:0] so index 0 maps to S0 (IV), index 4 maps to S4
    typedef ascon_word_t [NUM_WORDS-1:0] ascon_state_t;

    // Round constant type
    typedef logic [3:0] rnd_t;

    // 4-bit TUSER encoding for AXI4-Stream
    typedef enum logic [TUSER_WIDTH-1:0] {
        TUSER_RESERVED = 4'b0000,

        // AEAD Inputs
        TUSER_KEY      = 4'b0001, // Incoming data is Key (K)
        TUSER_NONCE    = 4'b0010, // Incoming data is Nonce (N)
        TUSER_AD       = 4'b0011, // Incoming data is Associated Data (A)
        TUSER_PT       = 4'b0100, // Incoming data is Plaintext (P)
        TUSER_CT       = 4'b0101, // Incoming data is Ciphertext (C)
        TUSER_TAG      = 4'b0110, // Incoming data is Tag (T) - Decryption Verify

        // Hash / XOF Inputs
        TUSER_MSG      = 4'b0111, // Incoming data is Hash/XOF Message (M)
        TUSER_Z        = 4'b1000, // Incoming data is CXOF Customization String (Z)

        // Outputs (Used on m_axis_tuser)
        TUSER_DIGEST   = 4'b1001  // Outgoing data is Hash/XOF Digest
    } axi_tuser_t;

    // --- Core Data In Select Enum ---
    // Selects what data is being fed into the lascon core
    typedef enum logic [2:0] {
        MODE_AEAD_ENC   = 3'b000,
        MODE_AEAD_DEC   = 3'b001,
        MODE_HASH256    = 3'b010,
        MODE_XOF        = 3'b011,
        MODE_CXOF       = 3'b100
    } lascon_mode_t;

    // --- Lascon Core Data-In Select Enum ---
    // Selects what data is being fed into the lascon core
    typedef enum logic [1:0] {
        DATA_IN_AXI_SEL    = 2'b00,
        DATA_IN_AEAD_SEL   = 2'b01,
        DATA_IN_HASH_SEL   = 2'b10,
        DATA_IN_XOR_SEL    = 2'b11
    } data_sel_t;

    // --- XOR OP2 Select Enum ---
    // Selects what data is being fed into the xor unit
    typedef enum logic [1:0] {
        XOR_IN_AEAD_SEL = 2'b00,
        XOR_IN_HASH_SEL = 2'b01,
        XOR_IN_AXI_SEL  = 2'b10
    } xor_sel_t;

endpackage : lascon_pkg
