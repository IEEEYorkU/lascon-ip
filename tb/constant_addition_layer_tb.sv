/*
 * Module Name: constant_addition_layer_tb
 * Author(s): Patrick De Leo
 * Description:
 * Ref: NIST SP 800-232
 */

`timescale 1ns/1ps

import lascon_pkg::*;

module constant_addition_layer_tb;

    // Input and output signals for the dut
    logic round_config_i;
    rnd_t rnd_i;
    ascon_state_t state_array_i;
    ascon_state_t state_array_o;

    // Test signals
    ascon_state_t test_array_i;
    rnd_t test_rnd_i;

    // Error Tracking
    int error_count = 0;
    int prev_error_count = 0; // Variable to track errors per test

    constant_addition_layer dut (
        .rnd_i(rnd_i),
        .state_array_i(state_array_i),
        .state_array_o(state_array_o)
    );

    /*
     * Checks that the s0 = x1, s1 = x1, s3 = x3 and s4 = x4
     * In other words, that these registers remainded unchanged from the input.
     * As per ascon blah blah blah
     */
    task automatic check_unchanged(
        input rnd_t rnd,
        input ascon_state_t exp,
        input ascon_state_t dut_out
    );
        assert(
            dut_out[0] == exp[0] &
            dut_out[1] == exp[1] &
            dut_out[3] == exp[3] &
            dut_out[4] == exp[4]
        )
            $write("."); // Print dot for progress
        else begin
            error_count++;
            $error("\n[ERROR] x0, x1, x3, or x4 changed for Round: %0d!\nExpected: %16x, %16x, %16x, %16x\nGot:      %16x, %16x, %16x, %16x",
                    rnd, exp[0], exp[1], exp[3], exp[4], dut_out[0], dut_out[1], dut_out[3], dut_out[4]);
        end
    endtask

    /*
     * Checks that the output register s2 = expected output
     */
    task automatic check_output(
        input rnd_t rnd,
        input ascon_state_t exp,
        input ascon_state_t dut_out
    );
        assert(
            dut_out[2] == (exp[2] ^ dut.AsconRcLut[rnd])
        )
            $write("."); // Print dot for progress
        else begin
            error_count++;
            $error("\n[ERROR] Problem with s2 for Round: %0d!\nExpected: %16x\nGot:      %16x",
                    rnd, (exp[2] ^ dut.AsconRcLut[rnd]), dut_out[2]);
        end
    endtask

    task automatic rand_rnd(input logic config_i, output rnd_t test_rnd);
        if (config_i == 1'b1)
            test_rnd = rnd_t'($urandom_range(0, 11)); // Max 12 rounds
        else
            test_rnd = rnd_t'($urandom_range(4, 11));  // Max 8 rounds - starting from 4
    endtask

    // Generates a random input state array.
    task automatic rand_array(output ascon_state_t test_array);
        for (int i = 0; i < 5; i++) begin
            test_array[i] = {$urandom(), $urandom()};
        end
    endtask

    // Create clock
    logic clk;
    // Set up clock
    initial clk = 0;
    always #1 clk = ~clk;

    integer max_tests = 20;

    initial begin
        // *** Required for verilator ***
        $dumpfile("constant_addition_layer_tb.vcd");
        $dumpvars(0, constant_addition_layer_tb);

        error_count = 0;

        // Test 1 All Zero Input Array
        $display("\nTest 1: All Zero Input...");
        prev_error_count = error_count; // Snapshot errors before test
        test_array_i = '0;
        state_array_i = test_array_i;
        round_config_i = 1'd1;
        for (int i = 0; i < 12; i++) begin
            #1;
            test_rnd_i = rnd_t'(i);
            rnd_i = test_rnd_i;
            #1;
            check_unchanged(test_rnd_i, test_array_i, state_array_o);
            check_output(test_rnd_i, test_array_i, state_array_o);
        end
        if (error_count == prev_error_count) $display("\nSUCCESS: Test 1 Passed!");

        #1;

        // Test 2 Exhaustive Cases
        $display("\n\nTest 2: Exhaustive Random Input...");
        prev_error_count = error_count; // Snapshot errors before test
        round_config_i = 1'd1;
        for (int i = 0; i < max_tests; i++) begin
            #1;
            rand_rnd(round_config_i, test_rnd_i); // Pass config to randomizer
            rand_array(test_array_i);
            state_array_i = test_array_i;
            rnd_i = test_rnd_i;
            #1;
            check_unchanged(test_rnd_i, test_array_i, state_array_o);
            check_output(test_rnd_i, test_array_i, state_array_o);
        end
        if (error_count == prev_error_count) $display("\nSUCCESS: Test 2 Passed!");

        #1;

        // Test 3 Round 8 All Zeros
        $display("\n\nTest 3: All Zero Input (Config 0)...");
        prev_error_count = error_count; // Snapshot errors before test
        test_array_i = '0;
        state_array_i = test_array_i;
        round_config_i = 1'd0;
        // Only loop up to 8 rounds (4 through 11) for config 0
        for (int i = 4; i < 12; i++) begin
            #1;
            test_rnd_i = rnd_t'(i);
            rnd_i = test_rnd_i;
            #1;
            check_unchanged(test_rnd_i, test_array_i, state_array_o);
            check_output(test_rnd_i, test_array_i, state_array_o);
        end
        if (error_count == prev_error_count) $display("\nSUCCESS: Test 3 Passed!");

        #1;

        // Test 4 Round 8 Exhaustive Cases
        $display("\n\nTest 4: Exhaustive Random Input (Config 0)...");
        prev_error_count = error_count; // Snapshot errors before test
        round_config_i = 0;
        for (int i = 0; i < max_tests; i++) begin
            #1;
            rand_rnd(round_config_i, test_rnd_i); // Pass config to randomizer
            rand_array(test_array_i);
            state_array_i = test_array_i;
            rnd_i = test_rnd_i;
            #1;
            check_unchanged(test_rnd_i, test_array_i, state_array_o);
            check_output(test_rnd_i, test_array_i, state_array_o);
        end
        if (error_count == prev_error_count) $display("\nSUCCESS: Test 4 Passed!");

        // Final Evaluation
        if (error_count > 0) begin
            $fatal(1, "\n\n[FATAL] Constant Addition Layer Tests failed with %0d errors. See log above.", error_count);
        end else begin
            $display("\n\n---------------------------------------------------------");
            $display("SUCCESS: All Constant Addition Layer Tests Passed!");
            $display("---------------------------------------------------------");
        end

        $finish;
    end

endmodule
