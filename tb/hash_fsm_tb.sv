/* =============================================================================
 * Module Name: hash_fsm_tb
 * Author(s):   Kiet Le, Ailiya Jafri
 * Description:
 * Verification environment for the Ascon-Hash/XOF Control FSM.
 * Simulates AXI-Stream backpressure and the Ascon datapath delay.
 * ============================================================================= */

`timescale 1ns / 1ps
import lascon_pkg::*;

module hash_fsm_tb;

    // =======================================================================
    // Signals & DUT Instantiation
    // =======================================================================
    logic           clk;
    logic           rst;

    lascon_mode_t   mode_i;
    logic [31:0]    xof_len_i;
    logic           start_i;
    logic           abort_i;
    logic           busy_o;
    logic           done_o;

    logic           lascon_ready_i;
    logic           start_perm_o;
    logic           round_config_o;
    logic [2:0]     word_sel_o;
    ascon_word_t    data_o;
    logic           write_en_o;
    logic [1:0]     core_in_data_sel_o;
    logic [1:0]     xor_sel_o;

    axi_tuser_t     padded_tuser_i;
    logic           padded_tlast_i;
    logic           padded_tvalid_i;
    logic           padded_tready_o;

    logic [7:0]     m_axis_tkeep_o;
    axi_tuser_t     m_axis_tuser_o;
    logic           m_axis_tlast_o;
    logic           m_axis_tvalid_o;
    logic           m_axis_tready_i;

    hash_fsm dut (
        .clk                    (clk),
        .rst                    (rst),
        .mode_i                 (mode_i),
        .xof_len_i              (xof_len_i),
        .start_i                (start_i),
        .abort_i                (abort_i),
        .busy_o                 (busy_o),
        .done_o                 (done_o),
        .lascon_ready_i         (lascon_ready_i),
        .start_perm_o           (start_perm_o),
        .round_config_o         (round_config_o),
        .word_sel_o             (word_sel_o),
        .data_o                 (data_o),
        .write_en_o             (write_en_o),
        .core_in_data_sel_o     (core_in_data_sel_o),
        .xor_sel_o              (xor_sel_o),
        .padded_tuser_i         (padded_tuser_i),
        .padded_tlast_i         (padded_tlast_i),
        .padded_tvalid_i        (padded_tvalid_i),
        .padded_tready_o        (padded_tready_o),
        .m_axis_tkeep_o         (m_axis_tkeep_o),
        .m_axis_tuser_o         (m_axis_tuser_o),
        .m_axis_tlast_o         (m_axis_tlast_o),
        .m_axis_tvalid_o        (m_axis_tvalid_o),
        .m_axis_tready_i        (m_axis_tready_i)
    );

    // =======================================================================
    // Phase 1: The "Mock" Environment
    // =======================================================================

    // 1. Clock Generation
    initial clk = 0;
    always #5 clk = ~clk;

    // 2. The Mock Ascon Core (Delay Simulator)
    initial begin
        lascon_ready_i = 1'b1;
        forever begin
            @(posedge clk);
            if (start_perm_o) begin
                #1 lascon_ready_i = 1'b0; // Core goes busy
                // Simulate 12 clock cycles of permutation math
                repeat(12) @(posedge clk);
                #1 lascon_ready_i = 1'b1; // Core is done
            end
        end
    end

    // 3. The Mock AXI Sink (Downstream DMA)
    initial begin
        m_axis_tready_i = 1'b1; // Always ready for this test
    end

    // =======================================================================
    // Testbench Handshake Tasks
    // =======================================================================
    task automatic apply_reset();
        rst = 1;
        start_i = 0; abort_i = 0;
        mode_i = MODE_HASH256; xof_len_i = 0;
        padded_tvalid_i = 0; padded_tlast_i = 0; padded_tuser_i = TUSER_MSG;
        @(posedge clk); #1; rst = 0; @(posedge clk); #1;
    endtask

    // Simulates the Padder sending a 64-bit word
    task automatic send_padded_beat(input logic is_last, input axi_tuser_t tuser);
        padded_tvalid_i = 1'b1;
        padded_tlast_i  = is_last;
        padded_tuser_i  = tuser;
        // Wait until the FSM accepts the beat
        do @(posedge clk); while (!padded_tready_o);
        #1;
        padded_tvalid_i = 1'b0;
        padded_tlast_i  = 1'b0;
    endtask

    // Waits for the FSM to pulse the done signal
    task automatic wait_for_done();
        int timeout = 0;
        while (!done_o) begin
            @(posedge clk);
            timeout++;
            if (timeout > 1000) begin
                $error("[TIMEOUT] FSM never asserted done_o!");
                $finish;
            end
        end
        $display("   ---> FSM Done Pulse Received.");
    endtask

    // =======================================================================
    // Phase 3: Hardware Monitors (The "Security" Checks)
    // =======================================================================

    // Snoop the internal FSM state for our assertions
    wire [2:0] internal_state = dut.state;

    always @(posedge clk) begin
        if (!rst) begin
            // 1. The Capacity Leak Monitor
            // 3'd4 is STATE_ABSORB, 3'd5 is STATE_SQUEEZE
            if ((internal_state == 3'd4 || internal_state == 3'd5) && word_sel_o != 3'd0) begin
                $fatal(1, "[SECURITY BREACH] FSM attempted to read/write capacity (lane %0d) during data transfer!", word_sel_o);
            end

            // 2. The Handshake Collision Monitor
            if (start_perm_o && !lascon_ready_i) begin
                $fatal(1, "[HANDSHAKE ERROR] FSM pulsed start_perm_o while core was already busy!");
            end
        end
    end

    // =======================================================================
    // Phase 2: Main Test Execution
    // =======================================================================
    initial begin
        $dumpfile("hash_fsm_tb.vcd");
        $dumpvars(0, hash_fsm_tb);

        $display("\n==================================================");
        $display("   Starting Lascon Hash FSM Verification");
        $display("==================================================\n");

        // -------------------------------------------------------------------
        // TEST 1: The "Happy Path" (Single-Block Hash256)
        // -------------------------------------------------------------------
        $display("[TEST 1] Single-Block Hash256 (1 Absorb, 4 Squeezes)");
        apply_reset();
        mode_i    = MODE_HASH256;
        xof_len_i = 0; // standard 256-bit hash

        @(posedge clk); #1 start_i = 1;
        @(posedge clk); #1 start_i = 0;

        // Send exactly 1 padded message block
        send_padded_beat(.is_last(1'b1), .tuser(TUSER_MSG));

        wait_for_done();
        $display("   [PASS] Test 1 Completed.\n");

        // -------------------------------------------------------------------
        // TEST 2: Multi-Block Absorb
        // -------------------------------------------------------------------
        $display("[TEST 2] Multi-Block Absorb (3 Absorbs, 4 Squeezes)");
        apply_reset();
        mode_i    = MODE_HASH256;
        xof_len_i = 0;

        @(posedge clk); #1 start_i = 1;
        @(posedge clk); #1 start_i = 0;

        send_padded_beat(.is_last(1'b0), .tuser(TUSER_MSG)); // Block 1 (Not last)
        send_padded_beat(.is_last(1'b0), .tuser(TUSER_MSG)); // Block 2 (Not last)
        send_padded_beat(.is_last(1'b1), .tuser(TUSER_MSG)); // Block 3 (Last)

        wait_for_done();
        $display("   [PASS] Test 2 Completed.\n");

        // -------------------------------------------------------------------
        // TEST 3: Variable Length XOF Squeeze
        // -------------------------------------------------------------------
        $display("[TEST 3] Ascon-XOF Squeeze (10 Bytes = 2 Squeeze Words)");
        apply_reset();
        mode_i    = MODE_XOF;
        xof_len_i = 10; // 10 bytes should trigger the ceiling division to 2 words

        @(posedge clk); #1 start_i = 1;
        @(posedge clk); #1 start_i = 0;

        send_padded_beat(.is_last(1'b1), .tuser(TUSER_MSG));

        wait_for_done();
        $display("   [PASS] Test 3 Completed.\n");

        // -------------------------------------------------------------------
        // TEST 4: CXOF (Customization String + Message)
        // -------------------------------------------------------------------
        $display("[TEST 4] Ascon-CXOF (1 Z block, 1 M block, 4 Squeezes)");
        apply_reset();
        mode_i    = MODE_CXOF;
        xof_len_i = 32; // 32 bytes = 4 words

        @(posedge clk); #1 start_i = 1;
        @(posedge clk); #1 start_i = 0;

        // 1. Absorb Customization String (Z) - TLAST=1 but TUSER_Z
        // The FSM should intercept this and stay in the ABSORB phase.
        send_padded_beat(.is_last(1'b1), .tuser(TUSER_Z));

        // 2. Absorb Message (M) - TLAST=1 and TUSER_MSG
        // The FSM should now transition to SQUEEZE phase.
        send_padded_beat(.is_last(1'b1), .tuser(TUSER_MSG));

        wait_for_done();
        $display("   [PASS] Test 4 Completed.\n");

        // -------------------------------------------------------------------
        $display("==================================================");
        $display("   ALL TESTS PASSED SUCCESSFULLY!");
        $display("==================================================\n");
        $finish;
    end

endmodule
