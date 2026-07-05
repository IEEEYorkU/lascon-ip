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
    // AEAD Encryption Test Task
    // =======================================================================
    task automatic execute_aead_enc_test(
        input string       test_name,
        input ascon_word_t exp_ct[],         // Expected Ciphertext words (BE)
        input ascon_word_t exp_tag[2],       // Expected Tag words (BE) — always 2
        input ascon_word_t stream_data[],    // AXI input beats (LE): K0, K1, N0, N1, AD..., PT...
        input logic [7:0]  stream_keep[],
        input axi_tuser_t  stream_user[],
        input logic        stream_last[]
    );
        int target_ct_words = exp_ct.size();
        ascon_word_t hw_ct[];
        ascon_word_t hw_tag[2];
        int ct_words_collected = 0;
        int tag_words_collected = 0;
        logic monitor_done = 1'b0;

        hw_ct = new[target_ct_words];

        $display("[RUNNING] %s", test_name);

        apply_reset();
        mode_i = MODE_AEAD_ENC;
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
                while (!monitor_done) begin
                    @(posedge clk);
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (m_axis_tuser == TUSER_CT && m_axis_tkeep != 8'h00) begin
                            ascon_word_t mask = 64'h0;
                            for (int k = 0; k < 8; k++) begin
                                if (m_axis_tkeep[k]) mask |= (64'hFF << (8 * k));
                            end
                            hw_ct[ct_words_collected] = m_axis_tdata & mask;
                            ct_words_collected++;
                        end else if (m_axis_tuser == TUSER_TAG) begin
                            hw_tag[tag_words_collected] = m_axis_tdata;
                            tag_words_collected++;
                        end
                        if (m_axis_tlast && m_axis_tuser == TUSER_TAG) begin
                            monitor_done = 1'b1;
                        end
                    end
                end
            end
        join

        while (!done_o) @(posedge clk);

        // Verify Output CT
        for (int i = 0; i < target_ct_words; i++) begin
            if (swap_bytes(hw_ct[i]) !== exp_ct[i]) begin
                // $display("\n   [DEBUG DUMP] %s (CT)", test_name);
                // for(int j=0; j<target_ct_words; j++) $display("   Word %0d | EXP: %h | HW_SWAPPED: %h", j, exp_ct[j], swap_bytes(hw_ct[j]));
                $fatal(1, "   [FAIL] %s: Ciphertext mismatch on Word %0d.", test_name, i);
            end
        end

        // Verify Output Tag
        for (int i = 0; i < 2; i++) begin
            if (swap_bytes(hw_tag[i]) !== exp_tag[i]) begin
                // $display("\n   [DEBUG DUMP] %s (TAG)", test_name);
                for(int j=0; j<2; j++) $display("   Word %0d | EXP: %h | HW_SWAPPED: %h", j, exp_tag[j], swap_bytes(hw_tag[j]));
                $fatal(1, "   [FAIL] %s: Tag mismatch on Word %0d.", test_name, i);
            end
        end

        $display("   [PASS]");
    endtask

    // =======================================================================
    // AEAD Decryption Test Task
    // =======================================================================
    task automatic execute_aead_dec_test(
        input string       test_name,
        input ascon_word_t exp_pt[],         // Expected Plaintext words (BE)
        input ascon_word_t stream_data[],    // AXI input beats (LE): K0, K1, N0, N1, AD..., CT..., Tag0, Tag1
        input logic [7:0]  stream_keep[],
        input axi_tuser_t  stream_user[],
        input logic        stream_last[],
        input logic        expected_tag_fail = 1'b0
    );
        int target_pt_words = exp_pt.size();
        ascon_word_t hw_pt[];
        int pt_words_collected = 0;

        hw_pt = new[target_pt_words];

        $display("[RUNNING] %s", test_name);

        apply_reset();
        mode_i = MODE_AEAD_DEC;
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
                while (pt_words_collected < target_pt_words) begin
                    @(posedge clk);
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (m_axis_tuser == TUSER_PT && m_axis_tkeep != 8'h00) begin
                            ascon_word_t mask = 64'h0;
                            for (int k = 0; k < 8; k++) begin
                                if (m_axis_tkeep[k]) mask |= (64'hFF << (8 * k));
                            end
                            hw_pt[pt_words_collected] = m_axis_tdata & mask;
                            pt_words_collected++;
                        end
                    end
                end
            end
        join

        while (!done_o) @(posedge clk);

        if (tag_fail_o !== expected_tag_fail) begin
            // $display("   [DEBUG DUMP] %s", test_name);
            // $display("   Expected Tag Fail: %b | Actual: %b", expected_tag_fail, tag_fail_o);
            // In Decryption, the RTL compares core_data_i against rx_tag_r.
            // But they are only valid during ST_VERIFY. Let's just print rx_tag_r which was latched.
            // $display("   RTL Latched RX Tag: %h %h", dut.u_aead_fsm.rx_tag_r[0], dut.u_aead_fsm.rx_tag_r[1]);
            // And we can also display the expected tag (which was passed as stream data).
            $fatal(1, "   [FAIL] %s: Tag verification mismatch. Expected %b, got %b.", test_name, expected_tag_fail, tag_fail_o);
        end

        // Verify Output PT only if we expect it to succeed
        if (!expected_tag_fail) begin
            for (int i = 0; i < target_pt_words; i++) begin
                if (swap_bytes(hw_pt[i]) !== exp_pt[i]) begin
                    // $display("\n   [DEBUG DUMP] %s (PT)", test_name);
                    // for(int j=0; j<target_pt_words; j++) $display("   Word %0d | EXP: %h | HW_SWAPPED: %h", j, exp_pt[j], swap_bytes(hw_pt[j]));
                    $fatal(1, "   [FAIL] %s: Plaintext mismatch on Word %0d.", test_name, i);
                end
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

        $display("\nAscon-AEAD128 Tests");
        $display("-------------------------------------------------------------------------");

        // -------------------------------------------------------------------
        // Ascon-AEAD128 TEST 1: Encryption Base Case (1-block AD, 1-block PT, all zeros)
        // -------------------------------------------------------------------
        begin
            ascon_word_t AEAD128_IV = 64'h00001000808c0001;
            ascon_word_t K0 = 64'h0, K1 = 64'h0;
            ascon_word_t N0 = 64'h0, N1 = 64'h0;
            ascon_word_t AD0 = 64'h0, AD1 = 64'h0;
            ascon_word_t PT0 = 64'h0, PT1 = 64'h0;
            ascon_word_t exp_ct[] = new[2]; // 2 words for PT
            ascon_word_t exp_tag[2];

            // --- Initialization ---
            sw_ref_state[0] = AEAD128_IV;
            sw_ref_state[1] = K0;
            sw_ref_state[2] = K1;
            sw_ref_state[3] = N0;
            sw_ref_state[4] = N1;
            sw_ref_state = ascon_perm(1'b1, sw_ref_state);   // p^a (12 rounds)
            sw_ref_state[3] ^= K0;  sw_ref_state[4] ^= K1;  // Post-init key XOR

            // --- AD phase ---
            // Block 1 (Data)
            sw_ref_state[0] ^= AD0;  sw_ref_state[1] ^= AD1;
            sw_ref_state = ascon_perm(1'b0, sw_ref_state);   // p^b (8 rounds)
            // Block 2 (Padding injected by padder because TLAST=1 & perfectly aligned)
            sw_ref_state[0] ^= 64'h8000_0000_0000_0000;
            sw_ref_state = ascon_perm(1'b0, sw_ref_state);   // p^b (8 rounds)

            sw_ref_state[4] ^= 64'h1;                        // Domain separation

            // --- PT phase ---
            // Block 1 (Data) - TLAST was intercepted, so hardware triggers a permutation
            exp_ct[0] = sw_ref_state[0] ^ PT0;
            exp_ct[1] = sw_ref_state[1] ^ PT1;
            sw_ref_state[0] = exp_ct[0];  // State ← CT for encryption
            sw_ref_state[1] = exp_ct[1];
            sw_ref_state = ascon_perm(1'b0, sw_ref_state);   // p^b (8 rounds)

            // Block 2 (Padding injected by padder, TLAST=1) -> No permutation
            sw_ref_state[0] ^= 64'h8000_0000_0000_0000;
            // sw_ref_state[1] ^= 64'h0; // No-op

            // --- Finalization ---
            sw_ref_state[2] ^= K0;  sw_ref_state[3] ^= K1;  // Pre-perm key XOR (TAG_INIT: S2,S3)
            sw_ref_state = ascon_perm(1'b1, sw_ref_state);    // p^a (12 rounds)
            exp_tag[0] = sw_ref_state[3] ^ K0;               // Post-perm key XOR
            exp_tag[1] = sw_ref_state[4] ^ K1;

            execute_aead_enc_test("Ascon-AEAD128: Encryption (1-block AD, 1-block PT, All Zeros)",
                exp_ct, exp_tag,
                '{64'h0, 64'h0, 64'h0, 64'h0, 64'h0, 64'h0, 64'h0, 64'h0}, // K0, K1, N0, N1, AD0, AD1, PT0, PT1
                '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF},
                '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_PT, TUSER_PT},
                '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1}
            );

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 2: Decryption Base Case (Round-Trip, all zeros)
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_pt[] = new[2];
                exp_pt[0] = PT0;
                exp_pt[1] = PT1;

                // Stream: K0, K1, N0, N1, AD0, AD1, CT0, CT1, Tag0, Tag1
                execute_aead_dec_test("Ascon-AEAD128: Decryption Base Case (Round-Trip, all zeros)",
                    exp_pt,
                    '{64'h0, 64'h0, 64'h0, 64'h0, 64'h0, 64'h0, swap_bytes(exp_ct[0]), swap_bytes(exp_ct[1]), swap_bytes(exp_tag[0]), swap_bytes(exp_tag[1])},
                    '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1}
                );
            end
            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 2: Empty AD, 1-Block PT
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_ct[] = new[2];
                ascon_word_t exp_tag[2];
                ascon_word_t exp_pt[] = new[2];

                exp_ct[0] = swap_bytes(64'h0857ed8d78094ffe);
                exp_ct[1] = swap_bytes(64'h73d050622be52c15);
                exp_tag[0] = swap_bytes(64'hc4bd7ee75a5b419a);
                exp_tag[1] = swap_bytes(64'h724c15523dbd4855);
                exp_pt[0] = 64'h0000000000000000;
                exp_pt[1] = 64'h0000000000000000;

                execute_aead_enc_test("Ascon-AEAD128: Empty AD, 1-Block PT (Encryption)",
                    exp_ct, exp_tag,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_PT, TUSER_PT},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1}
                );

                execute_aead_dec_test("Ascon-AEAD128: Empty AD, 1-Block PT (Decryption)",
                    exp_pt,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0857ed8d78094ffe, 64'h73d050622be52c15, 64'hc4bd7ee75a5b419a, 64'h724c15523dbd4855},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1}
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 3: Partial AD, 1-Block PT
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_ct[] = new[2];
                ascon_word_t exp_tag[2];
                ascon_word_t exp_pt[] = new[2];

                exp_ct[0] = swap_bytes(64'h94803108c7950ed1);
                exp_ct[1] = swap_bytes(64'hb7ff380d4e889886);
                exp_tag[0] = swap_bytes(64'ha057f90d27a0d4e5);
                exp_tag[1] = swap_bytes(64'h18f374d01e7da8f4);
                exp_pt[0] = 64'h0000000000000000;
                exp_pt[1] = 64'h0000000000000000;

                execute_aead_enc_test("Ascon-AEAD128: Partial AD, 1-Block PT (Encryption)",
                    exp_ct, exp_tag,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000006e6f637361, 64'h0000000000000000, 64'h0000000000000000},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'h1f, 8'hff, 8'hff},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_PT, TUSER_PT},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b1}
                );

                execute_aead_dec_test("Ascon-AEAD128: Partial AD, 1-Block PT (Decryption)",
                    exp_pt,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000006e6f637361, 64'h94803108c7950ed1, 64'hb7ff380d4e889886, 64'ha057f90d27a0d4e5, 64'h18f374d01e7da8f4},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'h1f, 8'hff, 8'hff, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1}
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 4: Multi-Block AD (2 blocks), 1-Block PT
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_ct[] = new[2];
                ascon_word_t exp_tag[2];
                ascon_word_t exp_pt[] = new[2];

                exp_ct[0] = swap_bytes(64'hcbe3e86c002f16c8);
                exp_ct[1] = swap_bytes(64'h6c00e433e6886022);
                exp_tag[0] = swap_bytes(64'h892d0f63eff12bb2);
                exp_tag[1] = swap_bytes(64'h1155d24ff814f720);
                exp_pt[0] = 64'h0000000000000000;
                exp_pt[1] = 64'h0000000000000000;

                execute_aead_enc_test("Ascon-AEAD128: Multi-Block AD (2 blocks), 1-Block PT (Encryption)",
                    exp_ct, exp_tag,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h4141414141414141, 64'h4141414141414141, 64'h4141414141414141, 64'h4141414141414141, 64'h0000000000000000, 64'h0000000000000000},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_AD, TUSER_AD, TUSER_PT, TUSER_PT},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1}
                );

                execute_aead_dec_test("Ascon-AEAD128: Multi-Block AD (2 blocks), 1-Block PT (Decryption)",
                    exp_pt,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h4141414141414141, 64'h4141414141414141, 64'h4141414141414141, 64'h4141414141414141, 64'hcbe3e86c002f16c8, 64'h6c00e433e6886022, 64'h892d0f63eff12bb2, 64'h1155d24ff814f720},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1}
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 5: Partial Multi-Block AD (2 full + 1 partial), 1-Block PT
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_ct[] = new[2];
                ascon_word_t exp_tag[2];
                ascon_word_t exp_pt[] = new[2];

                exp_ct[0] = swap_bytes(64'h09a32b479552232c);
                exp_ct[1] = swap_bytes(64'h043602155ff21d15);
                exp_tag[0] = swap_bytes(64'h37ed31d38b703ae2);
                exp_tag[1] = swap_bytes(64'h44c08ee334c4ca35);
                exp_pt[0] = 64'h0000000000000000;
                exp_pt[1] = 64'h0000000000000000;

                execute_aead_enc_test("Ascon-AEAD128: Partial Multi-Block AD (2 full + 1 partial), 1-Block PT (Encryption)",
                    exp_ct, exp_tag,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h4141414141414141, 64'h4141414141414141, 64'h0000004141414141, 64'h0000000000000000, 64'h0000000000000000},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'h1f, 8'hff, 8'hff},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_AD, TUSER_PT, TUSER_PT},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1}
                );

                execute_aead_dec_test("Ascon-AEAD128: Partial Multi-Block AD (2 full + 1 partial), 1-Block PT (Decryption)",
                    exp_pt,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h4141414141414141, 64'h4141414141414141, 64'h0000004141414141, 64'h09a32b479552232c, 64'h043602155ff21d15, 64'h37ed31d38b703ae2, 64'h44c08ee334c4ca35},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'h1f, 8'hff, 8'hff, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1}
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 6: 1-Block AD, Empty PT
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_ct[] = new[0];
                ascon_word_t exp_tag[2];
                ascon_word_t exp_pt[] = new[0];

                exp_tag[0] = swap_bytes(64'h42b008e8a4f66c43);
                exp_tag[1] = swap_bytes(64'h1d3311e6a8074107);

                execute_aead_enc_test("Ascon-AEAD128: 1-Block AD, Empty PT (Encryption)",
                    exp_ct, exp_tag,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'h00},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_PT},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1}
                );

                execute_aead_dec_test("Ascon-AEAD128: 1-Block AD, Empty PT (Decryption)",
                    exp_pt,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0, 64'h42b008e8a4f66c43, 64'h1d3311e6a8074107},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'h00, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b1}
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 7: 1-Block AD, Partial PT
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_ct[] = new[1];
                ascon_word_t exp_tag[2];
                ascon_word_t exp_pt[] = new[1];

                exp_ct[0] = swap_bytes(64'h000000928c3b46ec);
                exp_tag[0] = swap_bytes(64'he67847287cc4506c);
                exp_tag[1] = swap_bytes(64'h8a5b1eed7a31e082);
                exp_pt[0] = swap_bytes(64'h0000006f6c6c6568);

                execute_aead_enc_test("Ascon-AEAD128: 1-Block AD, Partial PT (Encryption)",
                    exp_ct, exp_tag,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000006f6c6c6568},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'h1f},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_PT},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1}
                );

                execute_aead_dec_test("Ascon-AEAD128: 1-Block AD, Partial PT (Decryption)",
                    exp_pt,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h000000928c3b46ec, 64'he67847287cc4506c, 64'h8a5b1eed7a31e082},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'h1f, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b1}
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 8: 1-Block AD, Multi-Block PT (2 blocks)
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_ct[] = new[4];
                ascon_word_t exp_tag[2];
                ascon_word_t exp_pt[] = new[4];

                exp_ct[0] = swap_bytes(64'heeb10cadb00773d4);
                exp_ct[1] = swap_bytes(64'h86bea57250fabc5a);
                exp_ct[2] = swap_bytes(64'h1f13eb453763c639);
                exp_ct[3] = swap_bytes(64'hda4a7c2ed3d69bc7);
                exp_tag[0] = swap_bytes(64'hd8a2dc714f63aa94);
                exp_tag[1] = swap_bytes(64'h3bcfb52826e40788);
                exp_pt[0] = swap_bytes(64'h5050505050505050);
                exp_pt[1] = swap_bytes(64'h5050505050505050);
                exp_pt[2] = swap_bytes(64'h5050505050505050);
                exp_pt[3] = swap_bytes(64'h5050505050505050);

                execute_aead_enc_test("Ascon-AEAD128: 1-Block AD, Multi-Block PT (2 blocks) (Encryption)",
                    exp_ct, exp_tag,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h5050505050505050, 64'h5050505050505050, 64'h5050505050505050, 64'h5050505050505050},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_PT, TUSER_PT, TUSER_PT, TUSER_PT},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1}
                );

                execute_aead_dec_test("Ascon-AEAD128: 1-Block AD, Multi-Block PT (2 blocks) (Decryption)",
                    exp_pt,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'heeb10cadb00773d4, 64'h86bea57250fabc5a, 64'h1f13eb453763c639, 64'hda4a7c2ed3d69bc7, 64'hd8a2dc714f63aa94, 64'h3bcfb52826e40788},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_CT, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1}
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 9: Non-Zero Data Vectors
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_ct[] = new[2];
                ascon_word_t exp_tag[2];
                ascon_word_t exp_pt[] = new[2];

                exp_ct[0] = swap_bytes(64'h28e75d4038c7ddf5);
                exp_ct[1] = swap_bytes(64'h11a7d5e9dfb1493c);
                exp_tag[0] = 64'h9b77394172a7da76;
                exp_tag[1] = 64'hde16b478b7bb6326;
                exp_pt[0] = swap_bytes(64'h3736353433323130);
                exp_pt[1] = swap_bytes(64'h3f3e3d3c3b3a3938);

                execute_aead_enc_test("Ascon-AEAD128: Non-Zero Data Vectors (Encryption)",
                    exp_ct, exp_tag,
                    '{64'h0706050403020100, 64'h0f0e0d0c0b0a0908, 64'h1716151413121110, 64'h1f1e1d1c1b1a1918, 64'h2726252423222120, 64'h2f2e2d2c2b2a2928, 64'h3736353433323130, 64'h3f3e3d3c3b3a3938},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_PT, TUSER_PT},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1}
                );

                execute_aead_dec_test("Ascon-AEAD128: Non-Zero Data Vectors (Decryption)",
                    exp_pt,
                    '{64'h0706050403020100, 64'h0f0e0d0c0b0a0908, 64'h1716151413121110, 64'h1f1e1d1c1b1a1918, 64'h2726252423222120, 64'h2f2e2d2c2b2a2928, 64'h28e75d4038c7ddf5, 64'h11a7d5e9dfb1493c, 64'h76daa7724139779b, 64'h2663bbb778b416de},
                    '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1}
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 11: Negative (Corrupted Tag)
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_pt[] = new[2];
                exp_pt[0] = 64'h0;
                exp_pt[1] = 64'h0;
                execute_aead_dec_test("Ascon-AEAD128: Negative (Corrupted Tag)",
                    exp_pt,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'hbee15cfde0572384, 64'hd6eef52200aaec0a, 64'h10ac9f5095418dd0, 64'hea5a4abbce7a1753},
                    '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1},
                    1'b1
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 12: Negative (Corrupted CT)
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_pt[] = new[2];
                exp_pt[0] = 64'h0;
                exp_pt[1] = 64'h0;
                execute_aead_dec_test("Ascon-AEAD128: Negative (Corrupted CT)",
                    exp_pt,
                    '{64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'hbee15cfde0572380, 64'hd6eef52200aaec0a, 64'h10ac9f5095418ddc, 64'hea5a4abbce7a1753},
                    '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1},
                    1'b1
                );
            end

            // -------------------------------------------------------------------
            // Ascon-AEAD128 TEST 13: Negative (Wrong Key)
            // -------------------------------------------------------------------
            begin
                ascon_word_t exp_pt[] = new[2];
                exp_pt[0] = 64'h0;
                exp_pt[1] = 64'h0;
                execute_aead_dec_test("Ascon-AEAD128: Negative (Wrong Key)",
                    exp_pt,
                    '{64'h0101010101010101, 64'h0101010101010101, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'h0000000000000000, 64'hbee15cfde0572384, 64'hd6eef52200aaec0a, 64'h10ac9f5095418ddc, 64'hea5a4abbce7a1753},
                    '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF},
                    '{TUSER_KEY, TUSER_KEY, TUSER_NONCE, TUSER_NONCE, TUSER_AD, TUSER_AD, TUSER_CT, TUSER_CT, TUSER_TAG, TUSER_TAG},
                    '{1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1},
                    1'b1
                );
            end

        end

        $display("\n=========================================================================");
        $display("   ALL AXI STREAM AND MATH TESTS PASSED!");
        $display("=========================================================================\n");
        $finish;
    end

endmodule
