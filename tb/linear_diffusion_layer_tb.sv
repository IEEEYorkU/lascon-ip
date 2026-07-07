/*
 * Module Name: linear_diffusion_layer_tb
 * Author(s): Tirth Patel, Artin Kiany
 * Description: Test bench for linear_diffusion_layer.sv
 * Ref: NIST SP 800-232
 */

`timescale 1ns/1ps
import lascon_pkg::*;

module linear_diffusion_layer_tb;

    // DUT signals
    ascon_state_t state_i;
    ascon_state_t state_o;

    // DUT Instantiation
    linear_diffusion_layer dut (
        .state_array_i(state_i),
        .state_array_o(state_o)
    );

    ascon_state_t exp;
    int test_id;
    int num_random_tests;
    logic mismatch;

    // reference model: Right Circular Rotation (ROR). The corrcet behaviour of the Layer

    function automatic logic [63:0] ror64(input logic [63:0] data, input int shift);
        return (data >> shift) | (data << (64 - shift));
    endfunction

    // Compute expected output using the Ascon Sigma functions
    task automatic compute_expected(
        input  ascon_state_t in_state,
        output ascon_state_t exp_state
    );
        int r_a [5]; //rotation a
        int r_b [5]; //rotation b

        r_a[0] = 19;
        r_a[1] = 61;
        r_a[2] = 1;
        r_a[3] = 10;
        r_a[4] = 7;  // word rotation 1 from ascon pdf

        r_b[0] = 28;
        r_b[1] = 39;
        r_b[2] = 6;
        r_b[3] = 17;
        r_b[4] = 41; // word rotation 2 from ascon pdf

        for (int i = 0; i < 5; i++) begin
            exp_state[i] = in_state[i] ^ ror64(in_state[i], r_a[i]) ^ ror64(in_state[i], r_b[i]);
        end
    endtask

    // print mismatch

    task automatic fail_mismatch(input int tid, input ascon_state_t expected_val);
        $display("\n[FAIL] test_id=%0d", tid);
        for (int i = 0; i < 5; i++) begin
            $display(
                "  Word %0d | IN: %h | DUT: %h | EXP: %h",
                i, state_i[i], state_o[i], expected_val[i]
            );
        end
        $finish;
    endtask

    // helper: generate random 64-bit word

    function automatic logic [63:0] rand_word();
        return { $urandom(), $urandom() };
    endfunction

    // main tests

    initial begin

        test_id = 0;
        num_random_tests = 500;
        mismatch = 0;

        $display("Starting Linear Diffusion Layer Testbench");

        // Test 1: All zeros

        for (int i = 0; i < 5; i++) state_i[i] = 64'h0;

        #1;

        compute_expected(state_i, exp);

        mismatch = 0;
        for (int i = 0; i < 5; i++) if (state_o[i] !== exp[i]) mismatch = 1;

        if (mismatch) fail_mismatch(test_id, exp);
        $display("Test 1: All Zeros PASSED wohoo.");
        test_id++;

        // Test 2: 1 in 1st bit for all words

        for (int i = 0; i < 5; i++) begin
            for (int w = 0; w < 5; w++) state_i[w] = 64'h0;
            state_i[i] = 64'h1;
            #1;
            compute_expected(state_i, exp);

            mismatch = 0;
            for (int k = 0; k < 5; k++) if (state_o[k] !== exp[k]) mismatch = 1;

            if (mismatch) fail_mismatch(test_id, exp);
            $display("Test 2: Word %0d Bit 1 Test Passed wohoo.", i);
            test_id++;
        end

        // Test 3: randomised bit test

        $display("Starting %0d Random Regressions...", num_random_tests);

        for (int t = 0; t < num_random_tests; t++) begin
            for (int r = 0; r < 5; r++) state_i[r] = rand_word();
            #1;
            compute_expected(state_i, exp);

            mismatch = 0;
            for (int k = 0; k < 5; k++) if (state_o[k] !== exp[k]) mismatch = 1;

            if (mismatch) fail_mismatch(test_id, exp);
            test_id++;
        end

        $display("\nALL TESTS PASSED SUCCESSFULLY wohoo!");
        $finish;
    end

endmodule
