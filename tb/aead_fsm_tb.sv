/*
 * Module Name: ascon_aead_tb.sv
 * Aurthor(s): Arthur Sabadini
 * Description: Testbench for ascon_aead.sv
 *
 */

`timescale 1ns/1ps
import lascon_pkg::*;

module aead_fsm_tb;

    // -------------------------------------------------------------------------
    // 1. Explicit Signal Declarations
    // -------------------------------------------------------------------------
    logic                 clk = 0;
    logic                 rst = 0;
    lascon_mode_t         mode_i;
    logic                 start_i;
    logic                 busy_o;
    logic                 done_o;
    logic                 tag_fail_o;

    // Core Interface
    logic                 lascon_ready_i;
    ascon_word_t          core_data_i;
    logic                 start_perm_o;
    logic                 round_config_o;
    logic [2:0]           word_sel_o;
    ascon_word_t          data_o;
    logic                 write_en_o;
    logic                 xor_en_o;
    data_sel_t            in_data_sel_o;

    // Padder Interface
    ascon_word_t          padded_tdata_i;
    logic [7:0]           padded_tkeep_i;
    axi_tuser_t           padded_tuser_i;
    logic                 padded_tlast_i;
    logic                 padded_tvalid_i;
    logic                 padded_tready_o;

    // Output Stream
    ascon_word_t          m_axis_tdata_o;
    logic [7:0]           m_axis_tkeep_o;
    logic [3:0]           m_axis_tuser_o;
    logic                 m_axis_tlast_o;
    logic                 m_axis_tvalid_o;
    logic                 m_axis_tready_i;

    // -------------------------------------------------------------------------
    // 2. Explicit UUT Instantiation
    // -------------------------------------------------------------------------
    aead_fsm uut (
        .clk             (clk),
        .rst             (rst),
        .mode_i          (mode_i),
        .start_i         (start_i),
        .busy_o          (busy_o),
        .done_o          (done_o),
        .tag_fail_o      (tag_fail_o),
        .lascon_ready_i  (lascon_ready_i),
        .core_data_i     (core_data_i),
        .start_perm_o    (start_perm_o),
        .round_config_o  (round_config_o),
        .word_sel_o      (word_sel_o),
        .data_o          (data_o),
        .write_en_o      (write_en_o),
        .xor_en_o        (xor_en_o),
        .in_data_sel_o   (in_data_sel_o),
        .padded_tdata_i  (padded_tdata_i),
        .padded_tkeep_i  (padded_tkeep_i),
        .padded_tuser_i  (padded_tuser_i),
        .padded_tlast_i  (padded_tlast_i),
        .padded_tvalid_i (padded_tvalid_i),
        .padded_tready_o (padded_tready_o),
        .m_axis_tdata_o  (m_axis_tdata_o),
        .m_axis_tkeep_o  (m_axis_tkeep_o),
        .m_axis_tuser_o  (m_axis_tuser_o),
        .m_axis_tlast_o  (m_axis_tlast_o),
        .m_axis_tvalid_o (m_axis_tvalid_o),
        .m_axis_tready_i (m_axis_tready_i)
    );

    // Clock Generation
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // 3. Core Response Logic (Emulator)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst)
            lascon_ready_i <= 1'b1;
        else if (start_perm_o)
            lascon_ready_i <= 1'b0;
        else
            lascon_ready_i <= 1'b1;
    end

    // -------------------------------------------------------------------------
    // 4. Handshake Tasks with Fatal Timeouts
    // -------------------------------------------------------------------------

    // Task to wait for a signal condition with a strict timeout
    task automatic wait_with_timeout(ref logic sig, input logic val, input string name);
        int timeout_cnt = 0;
        const int MAX_WAIT = 100;
        while (sig !== val) begin
            @(negedge clk);
            timeout_cnt++;
            if (timeout_cnt >= MAX_WAIT) begin
                $display("\n[FATAL ERROR] Timeout waiting for %s to reach %b", name, val);
                $display("Current FSM State: %0d", uut.state_r);
                $fatal(1, "AEAD_FSM Deadlock Detected.");
            end
        end
    endtask

    // Task to drive a word through the padder interface with timeout on ready
    task automatic drive_input(ascon_word_t data, axi_tuser_t user, logic last);
        padded_tdata_i  = data;
        padded_tuser_i  = user;
        padded_tlast_i  = last;
        padded_tvalid_i = 1'b1;

        wait_with_timeout(padded_tready_o, 1'b1, "padded_tready_o");

        @(negedge clk);
        padded_tvalid_i = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // 5. Main Test Procedure
    // -------------------------------------------------------------------------
    initial begin
        $display("Starting AEAD FSM Testbench with Fatal Timeouts...");

        // Signal Initialization
        rst = 1;
        mode_i = MODE_AEAD_ENC;
        start_i = 0;
        core_data_i = 64'h0;
        padded_tdata_i = 64'h0;
        padded_tkeep_i = 8'hFF;
        padded_tuser_i = TUSER_RESERVED;
        padded_tlast_i = 0;
        padded_tvalid_i = 0;
        m_axis_tready_i = 1;

        repeat(5) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // --- TEST 1: Encryption ---
        $display("Executing Test 1: Encryption Flow");
        start_i = 1;
        @(negedge clk);
        start_i = 0;

        // Stage: Initialization (Key x2, Nonce x2)
        drive_input(64'h0011223344556677, TUSER_KEY,   0);
        drive_input(64'h8899AABBCCDDEEFF, TUSER_KEY,   0);
        drive_input(64'h0102030405060708, TUSER_NONCE, 0);
        drive_input(64'h090A0B0C0D0E0F10, TUSER_NONCE, 1);
        $write(".");

        // Stage: Associated Data (2 words to test 128-bit block boundaries)
        drive_input(64'h4144445F44415441, TUSER_AD, 0);
        drive_input(64'h4242424242424242, TUSER_AD, 1);
        $write(".");

        // Stage: Plaintext (2 words to test 128-bit block boundaries)
        drive_input(64'h504C41494E545854, TUSER_PT, 0);
        drive_input(64'h5858585858585858, TUSER_PT, 1);
        $write(".");

        // Finalization: Wait for done_o
        wait_with_timeout(done_o, 1'b1, "done_o");
        $display(" Success");

        // --- TEST 2: Decryption ---
        $display("Executing Test 2: Decryption Flow");
        rst = 1; #20 rst = 0; @(negedge clk);

        mode_i = MODE_AEAD_DEC;
        start_i = 1;
        @(negedge clk);
        start_i = 0;

        // Init phase
        drive_input(64'h0, TUSER_KEY, 0);   drive_input(64'h0, TUSER_KEY, 0);
        drive_input(64'h0, TUSER_NONCE, 0); drive_input(64'h0, TUSER_NONCE, 1);

        // Ciphertext phase (2 words to test 128-bit block boundaries)
        drive_input(64'h0, TUSER_CT, 0);
        drive_input(64'h0, TUSER_CT, 1);

        // Tag load for comparison
        drive_input(64'hDEADBEEFCAFEBABE, TUSER_TAG, 0);
        drive_input(64'h0123456789ABCDEF, TUSER_TAG, 1);
        $write(".");

        // Verification phase logic:
        // We supply the expected core data as the FSM transitions to ST_VERIFY
        // The FSM reads core_data_i twice.
        core_data_i = 64'hDEADBEEFCAFEBABE; @(negedge clk);
        core_data_i = 64'h0123456789ABCDEF;

        wait_with_timeout(done_o, 1'b1, "done_o");

        if (tag_fail_o) $fatal(1, "Test Failed: Unexpected tag verification failure.");
        else            $display(" Success");

        $display("\n-----------------------------------------------------");
        $display("ALL AEAD FSM TESTS PASSED");
        $display("-----------------------------------------------------");
        $finish;
    end

endmodule
