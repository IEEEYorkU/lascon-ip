/*
 * Module Name: lascon_padder_tb
 * Author(s):   Kiet Le, Tirth Patel, Kevin Duong
 * Description: Testbench for lascon_padder.sv
 * Ref: NIST SP 800-232
 */
`timescale 1ns/1ps
import lascon_pkg::*;

module lascon_padder_tb;

    // DUT signals
    logic        clk, rst;
    lascon_mode_t mode_i;

    ascon_word_t s_axis_tdata_i;
    logic [7:0]  s_axis_tkeep_i;
    axi_tuser_t  s_axis_tuser_i;
    logic        s_axis_tlast_i;
    logic        s_axis_tvalid_i;
    logic        s_axis_tready_o;

    ascon_word_t padded_tdata_o;
    logic [7:0]  padded_tkeep_o;
    axi_tuser_t  padded_tuser_o;
    logic        padded_tlast_o;
    logic        padded_tvalid_o;
    logic        padded_tready_i;
    logic [7:0]  padded_tkeep_raw_o;
    logic        padded_is_padding_o;

    lascon_padder dut (.*);

    // Clock
    initial clk = 0;
    always #5 clk = ~clk;

    // Globals
    int test_id;
    int num_random_tests;
    int scenario;
    logic mismatch;

    // =========================================================================
    // Software Reference Models
    // =========================================================================

    // Simulates the physical wire-crossing Byte Swap
    function automatic ascon_word_t swap_bytes(input ascon_word_t data);
        return {data[7:0],   data[15:8],  data[23:16], data[31:24],
                data[39:32], data[47:40], data[55:48], data[63:56]};
    endfunction

    // Simulates the Big-Endian 0x80 padding injection
    function automatic ascon_word_t ref_padded(input ascon_word_t data, input logic [7:0] keep);
        ascon_word_t result = 64'b0;
        int byte_idx = 7; // Start placing at the MSB
        logic found = 1'b0;

        for (int i = 0; i < 8; i++) begin
            if (!found) begin
                if (keep[i] == 1'b1) begin
                    result[byte_idx*8 +: 8] = data[i*8 +: 8];
                    byte_idx--;
                end else begin
                    result[byte_idx*8 +: 8] = 8'h80;
                    found = 1'b1;
                end
            end
        end
        return result;
    endfunction

    // =========================================================================
    // Helpers & Tasks
    // =========================================================================
    function automatic ascon_word_t rand_word();
        return {$urandom(), $urandom()};
    endfunction

    // Generates a random partial keep mask
    function automatic logic [7:0] rand_partial_keep();
        int n;
        n = $urandom_range(1, 7); // 1–7 valid bytes, never full 0xFF
        return (8'h01 << n) - 1;  // e.g. n=3 → 8'h07
    endfunction

    task automatic apply_reset();
        rst = 1; s_axis_tvalid_i = 0; s_axis_tlast_i = 0;
        s_axis_tkeep_i = 8'hFF; s_axis_tdata_i = '0;
        s_axis_tuser_i = TUSER_RESERVED; padded_tready_i = 1;
        @(posedge clk); #1; rst = 0; @(posedge clk); #1;
    endtask

    task automatic send_beat(input ascon_word_t data, input logic [7:0] keep,
                   input axi_tuser_t tuser, input logic tlast);
        s_axis_tdata_i = data; s_axis_tkeep_i = keep;
        s_axis_tuser_i = tuser; s_axis_tlast_i = tlast; s_axis_tvalid_i = 1;
        do @(posedge clk); while (!s_axis_tready_o); #1;
        s_axis_tvalid_i = 0; s_axis_tlast_i = 0;
    endtask

    task automatic collect_beat(output ascon_word_t data, output logic [7:0] keep, output logic tlast);
        do @(posedge clk); while (!(padded_tvalid_o && padded_tready_i));
        data = padded_tdata_o; keep = padded_tkeep_o; tlast = padded_tlast_o; #1;
    endtask

    task automatic fail_mismatch(
        input int          tid,
        input string       label,
        input ascon_word_t got,
        input ascon_word_t exp_val,
        input logic [7:0]  got_keep,
        input logic        got_last
    );
        $display("\n[FAIL] test_id=%0d  (%s)", tid, label);
        $display("  DATA | EXP: %h | DUT: %h", exp_val, got);
        $display("  KEEP | DUT: %h  TLAST | DUT: %b", got_keep, got_last);
        $finish;
    endtask

    // Test variables
    ascon_word_t rand_d, beat_d, out_data, exp_data;
    logic [7:0]  rand_k, out_keep;
    logic        out_last;
    int          num_beats;

    // =========================================================================
    // MAIN
    // =========================================================================
    initial begin
        $dumpfile("lascon_padder_tb.vcd");
        $dumpvars(0, lascon_padder_tb);

        test_id          = 0;
        num_random_tests = 500;

        $display("Starting Lascon Padder Testbench");

        // =====================================================================
        // Test 1: GROUP A pass-through (KEY) — Expected swapped data
        // =====================================================================
        apply_reset(); mode_i = MODE_AEAD_ENC;
        rand_d = rand_word();
        fork
            begin
                send_beat(rand_d, 8'hFF, TUSER_KEY, 0);
                send_beat(rand_d, 8'hFF, TUSER_KEY, 1);
            end
            begin
                collect_beat(out_data, out_keep, out_last);
                mismatch = (out_data !== swap_bytes(rand_d)) || out_last; // Swapped check
                if (mismatch) fail_mismatch(test_id, "KEY beat0", out_data, swap_bytes(rand_d), out_keep, out_last);

                collect_beat(out_data, out_keep, out_last);
                mismatch = (out_data !== swap_bytes(rand_d)) || !out_last; // Swapped check
                if (mismatch) fail_mismatch(test_id, "KEY beat1", out_data, swap_bytes(rand_d), out_keep, out_last);
            end
        join
        $display("Test 1: KEY Pass-Through PASSED.");
        test_id++;

        // =====================================================================
        // Test 2: HASH partial final word — 0x80 injected, tkeep forced 0xFF
        // =====================================================================
        apply_reset(); mode_i = MODE_HASH256;
        rand_d   = rand_word();
        rand_k   = rand_partial_keep();
        exp_data = ref_padded(rand_d, rand_k); // Now Big-Endian
        fork
            send_beat(rand_d, rand_k, TUSER_MSG, 1);
            begin
                collect_beat(out_data, out_keep, out_last);
                mismatch = (out_data !== exp_data) || (out_keep !== 8'hFF) || !out_last;
                if (mismatch) fail_mismatch(test_id, "HASH partial", out_data, exp_data, out_keep, out_last);
            end
        join
        $display("Test 2: HASH Partial Final Word PASSED.");
        test_id++;

        // =====================================================================
        // Test 3: HASH full final word — carry block 0x8000...0000 must follow
        // =====================================================================
        apply_reset(); mode_i = MODE_HASH256;
        rand_d = rand_word();
        fork
            send_beat(rand_d, 8'hFF, TUSER_MSG, 1);
            begin
                collect_beat(out_data, out_keep, out_last);
                mismatch = (out_data !== swap_bytes(rand_d)) || out_last; // Swapped check
                if (mismatch) fail_mismatch(test_id, "HASH full word0", out_data, swap_bytes(rand_d), out_keep, out_last);
                collect_beat(out_data, out_keep, out_last);
                mismatch = (out_data !== 64'h8000_0000_0000_0000) || !out_last;
                if (mismatch) fail_mismatch(test_id, "HASH carry", out_data, 64'h8000_0000_0000_0000, out_keep, out_last);
            end
        join
        $display("Test 3: HASH Full Final Word (Carry Block) PASSED.");
        test_id++;

        // =====================================================================
        // Test 4: AEAD partial final on word0 — zero word1 appended for 128-bit rate
        // =====================================================================
        apply_reset(); mode_i = MODE_AEAD_ENC;
        rand_d   = rand_word();
        rand_k   = rand_partial_keep();
        exp_data = ref_padded(rand_d, rand_k);
        fork
            send_beat(rand_d, rand_k, TUSER_PT, 1);
            begin
                collect_beat(out_data, out_keep, out_last);
                mismatch = (out_data !== exp_data) || (out_keep !== 8'hFF) || out_last;
                if (mismatch) fail_mismatch(test_id, "AEAD word0", out_data, exp_data, out_keep, out_last);
                collect_beat(out_data, out_keep, out_last);
                mismatch = (out_data !== 64'h0) || !out_last;
                if (mismatch) fail_mismatch(test_id, "AEAD word1 zero", out_data, 64'h0, out_keep, out_last);
            end
        join
        $display("Test 4: AEAD Rate Alignment (Zero Word1) PASSED.");
        test_id++;

        // =====================================================================
        // Test 5: CT strict pass-through — tkeep untouched
        // =====================================================================
        apply_reset(); mode_i = MODE_AEAD_DEC;
        rand_d = rand_word();
        rand_k = rand_partial_keep();
        fork
            send_beat(rand_d, rand_k, TUSER_CT, 1);
            begin
                collect_beat(out_data, out_keep, out_last);
                mismatch = (out_data !== swap_bytes(rand_d)) || (out_keep !== rand_k) || !out_last; // Swapped check
                if (mismatch) fail_mismatch(test_id, "CT pass-through", out_data, swap_bytes(rand_d), out_keep, out_last);
            end
        join
        $display("Test 5: CT Strict Pass-Through PASSED.");
        test_id++;

        // =====================================================================
        // Test 6: AEAD sideband check (partial block)
        // =====================================================================
        apply_reset(); mode_i = MODE_AEAD_ENC;
        rand_d = rand_word();
        fork
            send_beat(rand_d, 8'h0F, TUSER_PT, 1);
            begin
                do @(posedge clk); while (!(padded_tvalid_o && padded_tready_i));
                if (padded_tkeep_raw_o !== 8'h0F || padded_is_padding_o !== 1'b0) begin
                    $display("\n[FAIL] test_id=%0d (AEAD Sideband partial)", test_id);
                    $display("  RAW_KEEP | EXP: %h | DUT: %h", 8'h0F, padded_tkeep_raw_o);
                    $display("  IS_PAD   | EXP: %b | DUT: %b", 1'b0, padded_is_padding_o);
                    $finish;
                end
                out_data = padded_tdata_o; out_keep = padded_tkeep_o; out_last = padded_tlast_o; #1;

                // Collect word 1
                collect_beat(out_data, out_keep, out_last);
            end
        join
        $display("Test 6: AEAD Sideband Check (Partial Block) PASSED.");
        test_id++;

        // =====================================================================
        // Test 7: AEAD sideband check (rollover padding)
        // =====================================================================
        apply_reset(); mode_i = MODE_AEAD_ENC;
        rand_d = rand_word();
        fork
            send_beat(rand_d, 8'hFF, TUSER_PT, 1);
            begin
                // Beat 1: Full payload
                do @(posedge clk); while (!(padded_tvalid_o && padded_tready_i));
                if (padded_tkeep_raw_o !== 8'hFF || padded_is_padding_o !== 1'b0) begin
                    $display("\n[FAIL] test_id=%0d (AEAD Sideband rollover beat0)", test_id);
                    $display("  RAW_KEEP | EXP: %h | DUT: %h", 8'hFF, padded_tkeep_raw_o);
                    $display("  IS_PAD   | EXP: %b | DUT: %b", 1'b0, padded_is_padding_o);
                    $finish;
                end
                out_data = padded_tdata_o; out_keep = padded_tkeep_o; out_last = padded_tlast_o; #1;

                // Beat 2: Pure padding block (word0)
                do @(posedge clk); while (!(padded_tvalid_o && padded_tready_i));
                if (padded_tkeep_raw_o !== 8'h00 || padded_is_padding_o !== 1'b1) begin
                    $display("\n[FAIL] test_id=%0d (AEAD Sideband rollover beat1)", test_id);
                    $display("  RAW_KEEP | EXP: %h | DUT: %h", 8'h00, padded_tkeep_raw_o);
                    $display("  IS_PAD   | EXP: %b | DUT: %b", 1'b1, padded_is_padding_o);
                    $finish;
                end
                out_data = padded_tdata_o; out_keep = padded_tkeep_o; out_last = padded_tlast_o; #1;
            end
        join
        $display("Test 7: AEAD Sideband Check (Rollover Block) PASSED.");
        test_id++;

        // =====================================================================
        // Test 8: Random regression — 500 iterations across all 4 scenarios
        // =====================================================================
        $display("Starting %0d Random Regressions...", num_random_tests);
        for (int t = 0; t < num_random_tests; t++) begin
            scenario  = $urandom_range(0, 3);
            num_beats = $urandom_range(0, 3);
            rand_d    = rand_word();

            // (a) HASH partial tkeep
            if (scenario == 0) begin
                apply_reset(); mode_i = MODE_HASH256;
                rand_k   = rand_partial_keep();
                exp_data = ref_padded(rand_d, rand_k);
                fork
                    begin
                        for (int b = 0; b < num_beats; b++) send_beat(rand_word(), 8'hFF, TUSER_MSG, 0);
                        send_beat(rand_d, rand_k, TUSER_MSG, 1);
                    end
                    begin
                        for (int b = 0; b < num_beats; b++) collect_beat(out_data, out_keep, out_last); // Ignores full words
                        collect_beat(out_data, out_keep, out_last);
                        mismatch = (out_data !== exp_data) || (out_keep !== 8'hFF) || !out_last;
                        if (mismatch) fail_mismatch(test_id, "RAND HASH partial", out_data, exp_data, out_keep, out_last);
                    end
                join

            // (b) HASH full tkeep → carry block
            end else if (scenario == 1) begin
                apply_reset(); mode_i = MODE_HASH256;
                fork
                    begin
                        for (int b = 0; b < num_beats; b++) send_beat(rand_word(), 8'hFF, TUSER_MSG, 0);
                        send_beat(rand_d, 8'hFF, TUSER_MSG, 1);
                    end
                    begin
                        for (int b = 0; b < num_beats; b++) collect_beat(out_data, out_keep, out_last);
                        collect_beat(out_data, out_keep, out_last);
                        mismatch = (out_data !== swap_bytes(rand_d)) || out_last; // Swapped check
                        if (mismatch) fail_mismatch(test_id, "RAND HASH full word0", out_data, swap_bytes(rand_d), out_keep, out_last);
                        collect_beat(out_data, out_keep, out_last);
                        mismatch = (out_data !== 64'h8000_0000_0000_0000) || !out_last;
                        if (mismatch) fail_mismatch(test_id, "RAND HASH carry", out_data, 64'h8000_0000_0000_0000, out_keep, out_last);
                    end
                join

            // (c) AEAD partial on word0
            end else if (scenario == 2) begin
                apply_reset(); mode_i = MODE_AEAD_ENC;
                rand_k    = rand_partial_keep();
                exp_data  = ref_padded(rand_d, rand_k);
                num_beats = $urandom_range(0, 2) * 2; // Keep alignment even
                fork
                    begin
                        for (int b = 0; b < num_beats; b++) send_beat(rand_word(), 8'hFF, TUSER_PT, 0);
                        send_beat(rand_d, rand_k, TUSER_PT, 1);
                    end
                    begin
                        for (int b = 0; b < num_beats; b++) collect_beat(out_data, out_keep, out_last);
                        collect_beat(out_data, out_keep, out_last);
                        mismatch = (out_data !== exp_data) || (out_keep !== 8'hFF) || out_last;
                        if (mismatch) fail_mismatch(test_id, "RAND AEAD word0", out_data, exp_data, out_keep, out_last);
                        collect_beat(out_data, out_keep, out_last);
                        mismatch = (out_data !== 64'h0) || !out_last;
                        if (mismatch) fail_mismatch(test_id, "RAND AEAD word1", out_data, 64'h0, out_keep, out_last);
                    end
                join

            // (d) CT strict pass-through
            end else begin
                apply_reset(); mode_i = MODE_AEAD_DEC;
                rand_k = rand_partial_keep();
                fork
                    send_beat(rand_d, rand_k, TUSER_CT, 1);
                    begin
                        collect_beat(out_data, out_keep, out_last);
                        mismatch = (out_data !== swap_bytes(rand_d)) || (out_keep !== rand_k) || !out_last; // Swapped check
                        if (mismatch) fail_mismatch(test_id, "RAND CT pass", out_data, swap_bytes(rand_d), out_keep, out_last);
                    end
                join
            end

            test_id++;
        end

        $display("\nALL TESTS PASSED SUCCESSFULLY wohoo!");
        $finish;
    end

    // Watchdog
    initial begin #5000000; $fatal(1, "TIMEOUT"); end

endmodule
