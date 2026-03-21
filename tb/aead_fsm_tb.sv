/*
 * Module Name: ascon_aead_tb.sv
 * Aurthor(s): Arthur Sabadini
 * Description: Testbench for ascon_aead.sv
 *
 */

`timescale 1ns/1ps
import ascon_pkg::*;

module aead_fsm_tb;

    // =========================
    // Clock / Reset
    // =========================
    logic clk = 0;
    logic rst = 0;
    always #5 clk = ~clk;

    // =========================
    // AEAD Control
    // =========================
    ascon_mode_t mode_i;
    logic start_i, busy_o, done_o, tag_fail_o;

    // =========================
    // AEAD <-> CORE Interface
    // =========================
    logic          start_perm_o, round_config_o;
    logic [2:0]    word_sel_o;
    ascon_word_t   data_o;
    logic          write_en_o;

    logic          ascon_ready_i;
    ascon_word_t   core_data_i;

    // =========================
    // AXI Input
    // =========================
    ascon_word_t padded_tdata_i;
    logic [7:0]  padded_tkeep_i;
    axi_tuser_t  padded_tuser_i;
    logic        padded_tlast_i;
    logic        padded_tvalid_i;
    logic        padded_tready_o;

    // AXI Output
    ascon_word_t m_axis_tdata_o;
    logic [7:0]  m_axis_tkeep_o;
    logic [3:0]  m_axis_tuser_o;
    logic        m_axis_tlast_o;
    logic        m_axis_tvalid_o;
    logic        m_axis_tready_i;

    // =========================
    // Local constants
    // =========================
    localparam ascon_mode_t ENC = MODE_AEAD_ENC;
    localparam ascon_mode_t DEC = MODE_AEAD_DEC;

    // =========================
    // AEAD Instantiation
    // =========================
    aead_fsm dut (
        .clk(clk),
        .rst(rst),

        .mode_i(mode_i),
        .start_i(start_i),
        .busy_o(busy_o),
        .done_o(done_o),
        .tag_fail_o(tag_fail_o),

        .ascon_ready_i(ascon_ready_i),
        .core_data_i(core_data_i),

        .start_perm_o(start_perm_o),
        .round_config_o(round_config_o),
        .word_sel_o(word_sel_o),
        .data_o(data_o),
        .write_en_o(write_en_o),
        .xor_en_o(),
        .in_data_sel_o(),

        .padded_tdata_i(padded_tdata_i),
        .padded_tkeep_i(padded_tkeep_i),
        .padded_tuser_i(padded_tuser_i),
        .padded_tlast_i(padded_tlast_i),
        .padded_tvalid_i(padded_tvalid_i),
        .padded_tready_o(padded_tready_o),

        .m_axis_tdata_o(m_axis_tdata_o),
        .m_axis_tkeep_o(m_axis_tkeep_o),
        .m_axis_tuser_o(m_axis_tuser_o),
        .m_axis_tlast_o(m_axis_tlast_o),
        .m_axis_tvalid_o(m_axis_tvalid_o),
        .m_axis_tready_i(m_axis_tready_i)
    );

    // =========================
    // Ascon Core Instantiation
    // =========================
    ascon_core core (
        .clk(clk),
        .rst(rst),

        .start_perm_i(start_perm_o),
        .round_config_i(round_config_o),

        .word_sel_i(word_sel_o),
        .data_i(data_o),
        .write_en_i(write_en_o),

        .data_o(core_data_i),
        .ready_o(ascon_ready_i)
    );

    // =========================
    // Debug (optional)
    // =========================
    /*
    always @(posedge clk) begin
        $display("busy=%0d ready=%0d tvalid=%0d tready=%0d",
            busy_o, ascon_ready_i, padded_tvalid_i, padded_tready_o);
    end
    */

    always @(posedge clk) begin
        if (start_perm_o && !ascon_ready_i)
            $error("[CORE ERROR] start_perm_o asserted while core busy!");
    end

    // =========================
    // AXI Driver
    // =========================
    task automatic send_word(
        input ascon_word_t data,
        input axi_tuser_t user,
        input logic last
    );
        int timeout = 5000;

        // Drive and hold
        padded_tdata_i  <= data;
        padded_tuser_i  <= user;
        padded_tlast_i  <= last;
        padded_tkeep_i  <= 8'hFF;
        padded_tvalid_i <= 1;

        // Wait for handshake
        // Currently Failing, handshake not working
        while (!(padded_tvalid_i && padded_tready_o) && timeout > 0) begin
            @(posedge clk);
            timeout--;
        end

        if (timeout == 0)
            $fatal("[TIMEOUT] AXI input handshake failed");

        // Complete transfer
        @(posedge clk);
        padded_tvalid_i <= 0;
    endtask

    // =========================
    // AXI Read
    // =========================
    task automatic read_block(output logic [127:0] data);
        int timeout = 5000;
        logic [63:0] w0, w1;

        while (!m_axis_tvalid_o && timeout > 0) begin
            @(posedge clk);
            timeout--;
        end
        if (timeout == 0)
            $fatal("[TIMEOUT] No AXI output");

        w0 = m_axis_tdata_o;

        timeout = 5000;
        @(posedge clk);

        while (!m_axis_tvalid_o && timeout > 0) begin
            @(posedge clk);
            timeout--;
        end
        if (timeout == 0)
            $fatal("[TIMEOUT] Missing AXI word");

        w1 = m_axis_tdata_o;
        data = {w0, w1};
    endtask

    // =========================
    // Checker
    // =========================
    int error_count = 0;

    task automatic check_output(
        input logic [127:0] exp_data,
        input logic [127:0] exp_tag,
        input logic [127:0] got_data,
        input logic [127:0] got_tag
    );
        if (got_data === exp_data && got_tag === exp_tag) begin
            $write(".");
        end else begin
            error_count++;
            $error("\nMismatch!");
            $display("Expected D: %h Got: %h", exp_data, got_data);
            $display("Expected T: %h Got: %h", exp_tag, got_tag);
        end
    endtask

    // =========================
    // Test Vectors
    // =========================
    int fd, r;

    logic v_mode;
    logic [127:0] v_key, v_nonce, v_ad;
    logic [127:0] v_din, v_exp_dout, v_exp_tag;
    logic [127:0] dout, tag;

    // =========================
    // TEST
    // =========================
    initial begin
        // Init signals
        padded_tvalid_i = 0;
        padded_tdata_i  = 0;
        padded_tuser_i  = TUSER_RESERVED;
        padded_tlast_i  = 0;
        padded_tkeep_i  = 0;

        m_axis_tready_i = 1;
        start_i = 0;

        // Reset
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;

        $display("Running AEAD tests with REAL permutation...");

        fd = $fopen("verif/test_vectors/aead_vectors.txt", "r");
        if (fd == 0) $fatal("File error");

        while (!$feof(fd)) begin

            r = $fscanf(fd, "%b %h %h %h %h %h %h\n",
                v_mode, v_key, v_nonce, v_ad,
                v_din, v_exp_dout, v_exp_tag);

            mode_i = v_mode ? ENC : DEC;

            // Start aligned with first word
            @(posedge clk);
            start_i = 1;

            send_word(v_key[127:64],   TUSER_KEY,   0);

            @(posedge clk);
            start_i = 0;

            send_word(v_key[63:0],     TUSER_KEY,   0);
            send_word(v_nonce[127:64], TUSER_NONCE, 0);
            send_word(v_nonce[63:0],   TUSER_NONCE, 1);

            send_word(v_ad[127:64], TUSER_AD, 0);
            send_word(v_ad[63:0],   TUSER_AD, 1);

            if (v_mode) begin
                send_word(v_din[127:64], TUSER_PT, 0);
                send_word(v_din[63:0],   TUSER_PT, 1);
            end else begin
                send_word(v_din[127:64], TUSER_CT, 0);
                send_word(v_din[63:0],   TUSER_CT, 1);

                send_word(v_exp_tag[127:64], TUSER_TAG, 0);
                send_word(v_exp_tag[63:0],   TUSER_TAG, 1);
            end

            // Wait for completion
            int timeout = 10000;
            while (!done_o && timeout > 0) begin
                @(posedge clk);
                timeout--;
            end

            if (timeout == 0)
                $fatal("[TIMEOUT] done_o not asserted");

            read_block(dout);
            read_block(tag);

            check_output(v_exp_dout, v_exp_tag, dout, tag);
        end

        if (error_count > 0)
            $fatal(1, "\nFAILED with %0d errors", error_count);
        else
            $display("\nSUCCESS: All tests passed!");

        $finish;
    end

endmodule
