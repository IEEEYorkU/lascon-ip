/* =============================================================================
 * Module Name: ascon_top_tb
 * Author(s):   Kiet Le
 * Description:
 * End-to-end integration testbench for the Ascon Hardware Accelerator.
 * Dynamically compares the RTL output against the `permutations_sim_pkg`
 * software reference model and strictly asserts AXI4-Stream protocols.
 * ============================================================================= */

`timescale 1ns / 1ps
import ascon_pkg::*;
import permutations_sim_pkg::*;

module ascon_top_tb;

    // =======================================================================
    // Signals & DUT Instantiation
    // =======================================================================
    logic           clk;
    logic           rst;

    ascon_mode_t    mode_i;
    logic [31:0]    xof_len_i;
    logic           start_i;
    logic           abort_i;
    logic           busy_o;
    logic           done_o;
    logic           tag_fail_o;

    logic [63:0]    s_axis_tdata;
    logic [7:0]     s_axis_tkeep;
    logic [3:0]     s_axis_tuser;
    logic           s_axis_tlast;
    logic           s_axis_tvalid;
    logic           s_axis_tready;

    logic [63:0]    m_axis_tdata;
    logic [7:0]     m_axis_tkeep;
    logic [3:0]     m_axis_tuser;
    logic           m_axis_tlast;
    logic           m_axis_tvalid;
    logic           m_axis_tready;

    ascon_top dut (.*);

    // =======================================================================
    // Clock & Simulated DMA (Backpressure)
    // =======================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // Simulate downstream AXI DMA backpressure (Randomly stalls 20% of the time)
    always @(posedge clk) begin
        if (rst) m_axis_tready <= 1'b0;
        else m_axis_tready <= ($urandom_range(0, 100) > 20);
    end

    // =======================================================================
    // Cross-Tool AXI Protocol Assertions (Verilator & vsim Safe)
    // =======================================================================
    logic        prev_s_valid, prev_m_valid;
    logic        prev_s_ready, prev_m_ready;
    logic [63:0] prev_s_data,  prev_m_data;

    always_ff @(posedge clk) begin
        if (!rst) begin
            // Slave Interface Protocol Check
            if (prev_s_valid && !prev_s_ready) begin
                assert (s_axis_tvalid === 1'b1) else $fatal(1, "[AXI ERROR] S_AXIS: tvalid dropped while stalled!");
                assert (s_axis_tdata === prev_s_data) else $fatal(1, "[AXI ERROR] S_AXIS: tdata changed while stalled!");
            end

            // Master Interface Protocol Check
            if (prev_m_valid && !prev_m_ready) begin
                assert (m_axis_tvalid === 1'b1) else $fatal(1, "[AXI ERROR] M_AXIS: tvalid dropped while stalled!");
                assert (m_axis_tdata === prev_m_data) else $fatal(1, "[AXI ERROR] M_AXIS: tdata changed while stalled!");
            end
        end

        // Track state for next cycle evaluation
        prev_s_valid <= s_axis_tvalid; prev_s_ready <= s_axis_tready; prev_s_data <= s_axis_tdata;
        prev_m_valid <= m_axis_tvalid; prev_m_ready <= m_axis_tready; prev_m_data <= m_axis_tdata;
    end

    // =======================================================================
    // Testbench Helper Tasks
    // =======================================================================
    function automatic ascon_word_t swap_bytes(input ascon_word_t data);
        return {data[7:0],   data[15:8],  data[23:16], data[31:24],
                data[39:32], data[47:40], data[55:48], data[63:56]};
    endfunction

    task automatic apply_reset();
        rst = 1; start_i = 0; abort_i = 0;
        mode_i = MODE_HASH256; xof_len_i = 0;
        s_axis_tvalid = 0; s_axis_tlast = 0;
        s_axis_tdata = '0; s_axis_tkeep = '0; s_axis_tuser = '0;
        @(posedge clk); #1; rst = 0; @(posedge clk); #1;
    endtask

    // Unified, Dynamic Execution Task for Hash, XOF, and CXOF
    task automatic execute_hash_test(
        input string       test_name,
        input ascon_mode_t test_mode,
        input int          xof_len_bytes,
        input ascon_word_t exp_digest[],
        input ascon_word_t stream_data[],
        input logic [7:0]  stream_keep[],
        input axi_tuser_t  stream_user[],
        input logic        stream_last[]
    );
        int target_words = exp_digest.size();
        ascon_word_t hw_digest[];
        int words_collected = 0;

        hw_digest = new[target_words];

        $display("[RUNNING] %s", test_name);

        apply_reset();
        mode_i = test_mode; xof_len_i = xof_len_bytes;
        @(posedge clk); #1 start_i = 1; @(posedge clk); #1 start_i = 0;

        // Drive AXI Stream dynamically based on the input arrays
        fork
            // Thread 1: Driver
            begin
                for (int i = 0; i < stream_data.size(); i++) begin
                    s_axis_tdata  = stream_data[i];
                    s_axis_tkeep  = stream_keep[i];
                    s_axis_tuser  = stream_user[i];
                    s_axis_tlast  = stream_last[i];
                    s_axis_tvalid = 1'b1;

                    do @(posedge clk); while (!s_axis_tready);
                    #1;
                end
                s_axis_tvalid = 1'b0;
                s_axis_tlast  = 1'b0;
            end

            // Thread 2: Monitor
            begin
                while (words_collected < target_words) begin
                    @(posedge clk);
                    if (m_axis_tvalid && m_axis_tready) begin
                        hw_digest[words_collected] = m_axis_tdata;
                        words_collected++;
                        if (m_axis_tlast && words_collected != target_words)
                            $fatal(1, "   [FAIL] Premature TLAST asserted at word %0d!", words_collected);
                    end
                end
            end
        join

        // Wait for graceful shutdown or issue Abort for infinite XOF tests
        if (xof_len_bytes > 0 || test_mode == MODE_HASH256) begin
            while (!done_o) @(posedge clk);
        end else begin
            // Hold the abort signal high until the hardware acknowledges it
            @(posedge clk);
            abort_i = 1'b1;
            while (!done_o) @(posedge clk); // Wait for FSM to cleanly hit STATE_DONE
            abort_i = 1'b0;                 // De-assert safely
        end

        // Verify Output
        for (int i = 0; i < target_words; i++) begin
            if (swap_bytes(hw_digest[i]) !== exp_digest[i]) begin
                $display("\n   [DEBUG DUMP] %s", test_name);
                for(int j=0; j<target_words; j++) $display("   Word %0d | EXP: %h | HW_SWAPPED: %h", j, exp_digest[j], swap_bytes(hw_digest[j]));
                $fatal(1, "   [FAIL] %s: Digest mismatch on Word %0d.", test_name, i);
            end
        end

        $display("   [PASS]");
    endtask

    // =======================================================================
    // Main Test Execution
    // =======================================================================
    ascon_state_t sw_ref_state;
    ascon_word_t  exp_digest[];

    initial begin
        $display("\n=========================================================================");
        $display("   Ascon System Integration & Math Verification");
        $display("=========================================================================");

        $display(" \nAscon-Hash256 Tests");
        $display("-------------------------------------------------------------------------");

        // Pre-allocate the dynamic array for Hash256 (always 4 words)
        exp_digest = new[4];

        // -------------------------------------------------------------------
        // Ascon-Hash256 TEST 1: Empty Message Debug (0 Bytes)
        // -------------------------------------------------------------------
        sw_ref_state[0] = 64'h0000080100cc0002;
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h8000_0000_0000_0000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        exp_digest[0] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[1] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[2] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[3] = sw_ref_state[0];

        execute_hash_test("Ascon-Hash256: Empty Message (0 Bytes)", MODE_HASH256, 0, exp_digest,
            '{64'h0000_0000_0000_0000}, // LE Data
            '{8'h00},                   // Keep
            '{TUSER_MSG},               // User
            '{1'b1}                     // Last
        );

        // -------------------------------------------------------------------
        // Ascon-Hash256 TEST 2: Exact Block Boundary (8 Bytes: "password")
        // -------------------------------------------------------------------
        sw_ref_state[0] = 64'h0000080100cc0002;
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h70617373776f7264;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h8000_0000_0000_0000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        exp_digest[0] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[1] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[2] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[3] = sw_ref_state[0];

        execute_hash_test("Ascon-Hash256: Exact Block Boundary ('password')", MODE_HASH256, 0, exp_digest,
            '{64'h6472_6f77_7373_6170},
            '{8'hFF},
            '{TUSER_MSG},
            '{1'b1}
        );

        // -------------------------------------------------------------------
        // TEST 3: Multi-Beat Unaligned (11 Bytes: "hello world")
        // -------------------------------------------------------------------
        sw_ref_state[0] = 64'h0000080100cc0002;
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h68656c6c6f20776f;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h726c648000000000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        exp_digest[0] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[1] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[2] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[3] = sw_ref_state[0];

        execute_hash_test("Ascon-Hash256: Multi-Beat Unaligned ('hello world')", MODE_HASH256, 0, exp_digest,
            '{64'h6f77_206f_6c6c_6568, 64'h0000_0000_0064_6c72},
            '{8'hFF, 8'h07},
            '{TUSER_MSG, TUSER_MSG},
            '{1'b0, 1'b1}
        );

        // -------------------------------------------------------------------
        // TEST 4: Single-Beat Unaligned (5 Bytes: "ascon")
        // -------------------------------------------------------------------
        sw_ref_state[0] = 64'h0000080100cc0002;
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h6173636f6e800000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        exp_digest[0] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[1] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[2] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state); exp_digest[3] = sw_ref_state[0];

        execute_hash_test("Ascon-Hash256: Single-Beat Unaligned ('ascon')", MODE_HASH256, 0, exp_digest,
            '{64'h0000_006e_6f63_7361},
            '{8'h1F},
            '{TUSER_MSG},
            '{1'b1}
        );

        $display(" \nAscon-XOF128 Tests");
        $display("-------------------------------------------------------------------------");

        // -------------------------------------------------------------------
        // Ascon-XOF128 TEST 1: Empty Message, 16-Byte Output (2 Words)
        // -------------------------------------------------------------------
        // Re-allocate the dynamic array for 2 expected words
        exp_digest = new[2];

        // 1. Calculate Expected Result using Software Reference Model (BIG ENDIAN)
        // --- Initialization ---
        sw_ref_state[0] = 64'h0000080000cc0003; // <-- XOF128 IV ends in 3!
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Absorbing (0 Bytes) ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h8000_0000_0000_0000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Squeezing (16 Bytes = 2 Words) ---
        exp_digest[0] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state);
        exp_digest[1] = sw_ref_state[0];

        // 2. Execute Test
        execute_hash_test("Ascon-XOF128: Empty Message (16-Byte Squeeze)",
            MODE_XOF, 16, exp_digest,
            '{64'h0000_0000_0000_0000}, // LE Data
            '{8'h00},                   // Keep
            '{TUSER_MSG},               // User
            '{1'b1}                     // Last
        );

        // -------------------------------------------------------------------
        // Ascon-XOF128 TEST 2: Single-Beat Unaligned, 64-Byte Output (8 Words)
        // -------------------------------------------------------------------
        // Re-allocate the dynamic array for 8 expected words
        exp_digest = new[8];

        // 1. Calculate Expected Result using Software Reference Model (BIG ENDIAN)
        // --- Initialization ---
        sw_ref_state[0] = 64'h0000080000cc0003; // XOF128 IV
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Absorbing ("ascon" = 5 bytes) ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h6173636f6e800000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Squeezing (64 Bytes = 8 Words) ---
        // We can use a loop to cleanly generate extended digests!
        for (int i = 0; i < 8; i++) begin
            exp_digest[i] = sw_ref_state[0];
            // Only permute if there are more words to squeeze
            if (i < 7) begin
                sw_ref_state = ascon_perm(1'b1, sw_ref_state);
            end
        end

        // 2. Execute Test
        execute_hash_test("Ascon-XOF128: Single-Beat ('ascon', 64-Byte Squeeze)",
            MODE_XOF, 64, exp_digest,
            '{64'h0000_006e_6f63_7361}, // LE Data ("ascon")
            '{8'h1F},                   // Keep (5 bytes valid)
            '{TUSER_MSG},               // User
            '{1'b1}                     // Last
        );

        // -------------------------------------------------------------------
        // Ascon-XOF128 TEST 3: Exact Block Boundary (8 Bytes: "password")
        // -------------------------------------------------------------------
        // Squeezing 32 bytes (4 words)
        exp_digest = new[4];

        // 1. Calculate Expected Result using Software Reference Model
        sw_ref_state[0] = 64'h0000080000cc0003;
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Absorbing ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h70617373776f7264; // "password"
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h8000_0000_0000_0000; // Padder Spillover
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Squeezing ---
        for (int i = 0; i < 4; i++) begin
            exp_digest[i] = sw_ref_state[0];
            if (i < 3) sw_ref_state = ascon_perm(1'b1, sw_ref_state);
        end

        // 2. Execute Test
        execute_hash_test("Ascon-XOF128: Exact Block Boundary ('password', 32-Byte Squeeze)",
            MODE_XOF, 32, exp_digest,
            '{64'h6472_6f77_7373_6170}, // LE Data
            '{8'hFF},                   // Keep
            '{TUSER_MSG},               // User
            '{1'b1}                     // Last
        );

        // -------------------------------------------------------------------
        // Ascon-XOF128 TEST 4: Infinite Squeeze / Hardware Abort
        // -------------------------------------------------------------------
        // We will configure the HW for infinite squeezing (length = 0),
        // collect exactly 6 words, and then assert the abort_i wire.
        exp_digest = new[6];

        // 1. Calculate Expected Result using Software Reference Model
        sw_ref_state[0] = 64'h0000080000cc0003;
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Absorbing ("infinite") ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h696e66696e697465;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h8000_0000_0000_0000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Squeezing ---
        for (int i = 0; i < 6; i++) begin
            exp_digest[i] = sw_ref_state[0];
            if (i < 5) sw_ref_state = ascon_perm(1'b1, sw_ref_state);
        end

        // 2. Execute Test (Notice xof_len_bytes = 0)
        execute_hash_test("Ascon-XOF128: Infinite Squeeze & Abort ('infinite')",
            MODE_XOF, 0, exp_digest, // <--- 0 triggers infinite mode in the FSM
            '{64'h6574_696e_6966_6e69}, // LE Data
            '{8'hFF},                   // Keep
            '{TUSER_MSG},               // User
            '{1'b1}                     // Last
        );

        $display(" \nAscon-CXOF128 Tests");
        $display("-------------------------------------------------------------------------");

        // -------------------------------------------------------------------
        // Ascon-CXOF128 TEST 1: Empty Z, Empty M, 16-Byte Output (2 Words)
        // -------------------------------------------------------------------
        exp_digest = new[2];

        // 1. Calculate Expected Result using Software Reference Model (BIG ENDIAN)
        // --- Initialization ---
        sw_ref_state[0] = 64'h0000080000cc0004; // <-- CXOF128 IV ends in 4!
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Customization (Z) ---
        // Z_0: Length of Z in bits (0 bytes = 0 bits)
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h0000_0000_0000_0000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        // Z_1: Pad(Empty Z)
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h8000_0000_0000_0000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Absorbing (M) ---
        // M_0: Pad(Empty M)
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h8000_0000_0000_0000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Squeezing (16 Bytes = 2 Words) ---
        exp_digest[0] = sw_ref_state[0];
        sw_ref_state  = ascon_perm(1'b1, sw_ref_state);
        exp_digest[1] = sw_ref_state[0];

        // 2. Execute Test
        execute_hash_test("Ascon-CXOF128: Empty Z, Empty M (16-Byte Squeeze)",
            MODE_CXOF, 16, exp_digest,
            '{64'h0000_0000_0000_0000, 64'h0000_0000_0000_0000, 64'h0000_0000_0000_0000}, // Z_0, Z_pad, M_pad
            '{8'hFF, 8'h00, 8'h00},                    // Keeps
            '{TUSER_Z, TUSER_Z, TUSER_MSG},            // Users (FSM domain separation)
            '{1'b0, 1'b1, 1'b1}                        // Lasts (Trigger permutations)
        );

        // -------------------------------------------------------------------
        // Ascon-CXOF128 TEST 2: Valid Z and M, 32-Byte Output (4 Words)
        // -------------------------------------------------------------------
        exp_digest = new[4];

        // 1. Calculate Expected Result using Software Reference Model (BIG ENDIAN)
        // --- Initialization ---
        sw_ref_state[0] = 64'h0000080000cc0004; // CXOF128 IV
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Customization (Z = "custom") ---
        // Z_0: Length of Z in bits (6 bytes * 8 = 48 bits = 0x30)
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h0000_0000_0000_0030;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        // Z_1: "custom" + Pad (6 bytes) -> 64'h6375_7374_6f6d_8000
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h6375_7374_6f6d_8000;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Absorbing (M = "message") ---
        // M_0: "message" + Pad (7 bytes) -> 64'h6d65_7373_6167_6580
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h6d65_7373_6167_6580;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Squeezing (32 Bytes = 4 Words) ---
        for (int i = 0; i < 4; i++) begin
            exp_digest[i] = sw_ref_state[0];
            if (i < 3) sw_ref_state = ascon_perm(1'b1, sw_ref_state);
        end

        // 2. Execute Test
        // Note: We use Little-Endian for the AXI data array
        // Z_0 = 0x30. Byte-swapped for AXI LE = 64'h3000_0000_0000_0000
        // "custom"  = 6d 6f 74 73 75 63 -> 64'h0000_6d6f_7473_7563 (tkeep: 0x3F)
        // "message" = 65 67 61 73 73 65 6d -> 64'h0065_6761_7373_656d (tkeep: 0x7F)
        execute_hash_test("Ascon-CXOF128: Valid Z ('custom') and M ('message')",
            MODE_CXOF, 32, exp_digest,
            '{64'h3000_0000_0000_0000, 64'h0000_6d6f_7473_7563, 64'h0065_6761_7373_656d}, // Z_0 (swapped), Z_data, M_data
            '{8'hFF, 8'h3F, 8'h7F},                    // Keeps
            '{TUSER_Z, TUSER_Z, TUSER_MSG},            // Users
            '{1'b0, 1'b1, 1'b1}                        // Lasts
        );

        // -------------------------------------------------------------------
        // Ascon-CXOF128 TEST 3: Exact Block Boundary Z (8 Bytes) + Short M
        // -------------------------------------------------------------------
        // Z = "password" (8 bytes -> 64 bits = 0x40)
        // M = "ascon" (5 bytes)
        exp_digest = new[4];

        // 1. Calculate Expected Result
        sw_ref_state[0] = 64'h0000080000cc0004; // CXOF128 IV
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Customization (Z) ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h0000_0000_0000_0040; // Length = 64 bits (0x40)
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h70617373776f7264;    // "password"
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h8000_0000_0000_0000; // Padder spillover
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Absorbing (M) ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h6173636f6e800000;    // "ascon" + Pad
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Squeezing ---
        for (int i = 0; i < 4; i++) begin
            exp_digest[i] = sw_ref_state[0];
            if (i < 3) sw_ref_state = ascon_perm(1'b1, sw_ref_state);
        end

        // 2. Execute Test
        execute_hash_test("Ascon-CXOF128: Block Boundary Z ('password'), Short M ('ascon')",
            MODE_CXOF, 32, exp_digest,
            '{64'h4000_0000_0000_0000, 64'h6472_6f77_7373_6170, 64'h0000_006e_6f63_7361}, // Z_0, Z_data, M_data
            '{8'hFF, 8'hFF, 8'h1F},                    // Keeps (Note Z_data is 0xFF, forcing spillover)
            '{TUSER_Z, TUSER_Z, TUSER_MSG},            // Users
            '{1'b0, 1'b1, 1'b1}                        // Lasts
        );

        // -------------------------------------------------------------------
        // Ascon-CXOF128 TEST 4: Multi-Beat Z (11 Bytes) and M (11 Bytes)
        // -------------------------------------------------------------------
        // Z = "custom_str!" (11 bytes -> 88 bits = 0x58)
        // M = "hello world" (11 bytes)
        exp_digest = new[4];

        // 1. Calculate Expected Result
        sw_ref_state[0] = 64'h0000080000cc0004; // CXOF128 IV
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Customization (Z) ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h0000_0000_0000_0058; // Length = 88 bits (0x58)
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h637573746f6d5f73;    // "custom_s"
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h7472218000000000;    // "tr!" + pad
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Absorbing (M) ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h68656c6c6f20776f;    // "hello wo"
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h726c648000000000;    // "rld" + pad
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Squeezing ---
        for (int i = 0; i < 4; i++) begin
            exp_digest[i] = sw_ref_state[0];
            if (i < 3) sw_ref_state = ascon_perm(1'b1, sw_ref_state);
        end

        // 2. Execute Test
        execute_hash_test("Ascon-CXOF128: Multi-Beat Z ('custom_str!') and M ('hello world')",
            MODE_CXOF, 32, exp_digest,
            '{64'h5800_0000_0000_0000, 64'h735f_6d6f_7473_7563, 64'h0000_0000_0021_7274, 64'h6f77_206f_6c6c_6568, 64'h0000_0000_0064_6c72},
            '{8'hFF, 8'hFF, 8'h07, 8'hFF, 8'h07},
            '{TUSER_Z, TUSER_Z, TUSER_Z, TUSER_MSG, TUSER_MSG},
            '{1'b0, 1'b0, 1'b1, 1'b0, 1'b1}
        );

        // -------------------------------------------------------------------
        // Ascon-CXOF128 TEST 5: Infinite Squeeze & Abort
        // -------------------------------------------------------------------
        // Z = "Z" (1 byte -> 8 bits = 0x08)
        // M = "M" (1 byte)
        exp_digest = new[6]; // We will collect 6 words then abort

        // 1. Calculate Expected Result
        sw_ref_state[0] = 64'h0000080000cc0004; // CXOF128 IV
        sw_ref_state[1] = 64'b0; sw_ref_state[2] = 64'b0; sw_ref_state[3] = 64'b0; sw_ref_state[4] = 64'b0;
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Customization (Z) ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h0000_0000_0000_0008; // Length = 8 bits (0x08)
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h5a80_0000_0000_0000; // "Z" + pad
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Absorbing (M) ---
        sw_ref_state[0] = sw_ref_state[0] ^ 64'h4d80_0000_0000_0000; // "M" + pad
        sw_ref_state    = ascon_perm(1'b1, sw_ref_state);

        // --- Squeezing ---
        for (int i = 0; i < 6; i++) begin
            exp_digest[i] = sw_ref_state[0];
            if (i < 5) sw_ref_state = ascon_perm(1'b1, sw_ref_state);
        end

        // 2. Execute Test (xof_len_bytes = 0)
        execute_hash_test("Ascon-CXOF128: Infinite Squeeze & Abort",
            MODE_CXOF, 0, exp_digest,
            '{64'h0800_0000_0000_0000, 64'h0000_0000_0000_005a, 64'h0000_0000_0000_004d}, // Z_0, 'Z', 'M'
            '{8'hFF, 8'h01, 8'h01},
            '{TUSER_Z, TUSER_Z, TUSER_MSG},
            '{1'b0, 1'b1, 1'b1}
        );

        $display("\n=========================================================================");
        $display("   ALL AXI STREAM AND MATH TESTS PASSED!");
        $display("=========================================================================\n");
        $finish;
    end

endmodule
