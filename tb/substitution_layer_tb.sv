/*
 * Module Name: substitution_layer_tv.sv
 * Aurthor(s): Kevin Duong, Arthur Sabadini
 * Description: Testbench for substitution_layer.sv
 *
 */

`timescale 1ns/1ps
import lascon_pkg::*;

module substitution_layer_tb;

// Inputs and Registers DUT
ascon_state_t state_array_i;
ascon_state_t state_array_o;

//Instantiate DUT from substitution_layer:
substitution_layer dut (
    .state_array_i(state_array_i),
    .state_array_o(state_array_o)
);

/*
-------------------------------------------------------------------------
 * SBOX equations from NIST SP 800-232, Sec 3.3 Eq (7)
 * Mapping follows Eq (5): (s(0,j),...,s(4,j)) = SBOX(...)
 * So x0=s(0,j)=state_array_i[0][j], ..., x4=s(4,j)=state_array_i[4][j]
-------------------------------------------------------------------------
 */

//This is meant to be the expected output, we can use to compare
//the results from sbox_eq function to our actual implementation substitution_layer.sv
function automatic logic [4:0] sbox_eq(
    input logic x0, input logic x1, input logic x2, input logic x3, input logic x4
);

 logic y0, y1, y2, y3, y4;
 begin
    y0 = (x4 & x1) ^ x3 ^ (x2 & x1) ^ x2 ^ (x1 & x0) ^ x1 ^ x0;
    y1 = x4        ^ (x3 & x2) ^ (x3 & x1) ^ x3 ^ (x2 & x1) ^ x2 ^ x1 ^ x0;
    y2 = (x4 & x3) ^ x4 ^ x2 ^ x1 ^ 1'b1;
    y3 = (x4 & x0) ^ x4 ^ (x3 & x0) ^ x3 ^ x2 ^ x1 ^ x0;
    y4 = (x4 & x1) ^ x4 ^ x3 ^ (x1 & x0) ^ x1;

    //Return the outputs
    sbox_eq = {y0, y1, y2, y3, y4};
 end
endfunction

//Compute full-state expected output using sbox_eq function
task automatic compute_expected(
    input  ascon_state_t in_state,
    output ascon_state_t exp_state
);

    logic [4:0] y;
    for(int j = 0; j < WORD_WIDTH; j++) begin
        y = sbox_eq(
            in_state[0][j],
            in_state[1][j],
            in_state[2][j],
            in_state[3][j],
            in_state[4][j]
        );
        exp_state[0][j] = y[4];
        exp_state[1][j] = y[3];
        exp_state[2][j] = y[2];
        exp_state[3][j] = y[1];
        exp_state[4][j] = y[0];
    end
endtask

  //mismatch print
  task automatic fail_mismatch(input int test_id, input ascon_state_t exp);
    $display("\n[FAIL] test_id=%0d", test_id);
    $display("  IN : S0=%h S1=%h S2=%h S3=%h S4=%h",
             state_array_i[0],
             state_array_i[1],
             state_array_i[2],
             state_array_i[3],
             state_array_i[4]
            );

    $display("  DUT: S0=%h S1=%h S2=%h S3=%h S4=%h",
             state_array_o[0],
             state_array_o[1],
             state_array_o[2],
             state_array_o[3],
             state_array_o[4]
            );

    $display("  EXP: S0=%h S1=%h S2=%h S3=%h S4=%h\n",
             exp[0], exp[1], exp[2], exp[3], exp[4]);
    $fatal(1);
  endtask

   // Helper: randomize a 64-bit characters
  function automatic logic [WORD_WIDTH-1:0] rand_word();
    // WORD_WIDTH is expected 64 in Ascon
    rand_word = { $urandom(), $urandom() };
  endfunction

  initial begin
    ascon_state_t exp;
    int test_id = 0;
    int max_print = 2;

    // ----------------------------
    // Test 1: Directed SBOX sweep on a single bit position (j=0)
    // For all x in [0..31], set only bit j=0 to that tuple, everything else 0.
    // This checks the exact SBOX truth-table behavior. :contentReference[oaicite:2]{index=2}
    // ----------------------------
    $display("[TB] Directed SBOX sweep (bit j=0) ...");
    for (int x = 0; x < 32; x++) begin
      // clear entire input
      foreach (state_array_i[w]) state_array_i[w] = '0;

      // Apply x bits to (s(0,0)..s(4,0)) where x = {x0,x1,x2,x3,x4}
      // x0 is MSB of the 5-bit value, x4 is LSB (matches the spec note). :contentReference[oaicite:3]{index=3}
      state_array_i[0][0] = x[4];
      state_array_i[1][0] = x[3];
      state_array_i[2][0] = x[2];
      state_array_i[3][0] = x[1];
      state_array_i[4][0] = x[0];

      #1;
      compute_expected(state_array_i, exp);

      if (state_array_o !== exp) fail_mismatch(test_id, exp);
      test_id++;
    end
    $display("[TB] Directed sweep PASSED.");

    // ----------------------------
    // Test 2: Random full-state regression
    // ----------------------------

    $display("[TB] Random regression ...");

    for (int t = 0; t < 500; t++) begin
      state_array_i[0] = rand_word();
      state_array_i[1] = rand_word();
      state_array_i[2] = rand_word();
      state_array_i[3] = rand_word();
      state_array_i[4] = rand_word();

      #1;
      compute_expected(state_array_i, exp);

    //Just to see the values for the first few tests
    //IN: Input state
    //DUT: Output from substitution_layer.sv DUT
    //EXP: Expected output from sbox_eq function
      if (t < max_print) begin
        $display("[TB] rand t=%0d test_id=%0d IN : S0=%h S1=%h S2=%h S3=%h S4=%h",
                 t, test_id,
                 state_array_i[0], state_array_i[1], state_array_i[2],
                 state_array_i[3], state_array_i[4]);
        $display("[TB] rand t=%0d test_id=%0d DUT: S0=%h S1=%h S2=%h S3=%h S4=%h",
                 t, test_id,
                 state_array_o[0], state_array_o[1], state_array_o[2],
                 state_array_o[3], state_array_o[4]);
        $display("[TB] rand t=%0d test_id=%0d EXP: S0=%h S1=%h S2=%h S3=%h S4=%h",
                 t, test_id,
                 exp[0], exp[1], exp[2], exp[3], exp[4]);
      end

      if (state_array_o !== exp) fail_mismatch(test_id, exp);
      test_id++;
    end
    $display("[TB] Random regression PASSED.");

    $display("\n[TB] ALL TESTS PASSED ");
    $finish;
  end

endmodule
