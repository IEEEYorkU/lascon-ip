/*
 * Package Name: permutations_sim
 * Author: Arthur Sabadini, Kevin Duong, Tirth Patel, Artin Kiany, Sasha Calmels, Patrick de Leo
 * Description: Functions used to simulate the output of each permutation
 * Ref: NIST SP 800-232
 */

`timescale 1ns / 1ps

package permutations_sim_pkg;

    import lascon_pkg::*;

    // ----------------------------------------------------------
    // Constant Addition Layer Simulation
    // ----------------------------------------------------------

    // 12-entry LUT, each entry is 8 bit round constant
    localparam logic [7:0] ConstAddLUT [12] = '{
        8'hf0, // i=0
        8'he1, // i=1
        8'hd2, // i=2
        8'hc3, // i=3
        8'hb4, // i=4
        8'ha5, // i=5
        8'h96, // i=6
        8'h87, // i=7
        8'h78, // i=8
        8'h69, // i=9
        8'h5a, // i=10
        8'h4b // i=11
    };

    function automatic ascon_state_t addition(
        input rnd_t rnd,
        input logic round_config_i,
        input ascon_state_t state_array_i
    );

        ascon_state_t state_array_o;
        begin
            state_array_o = state_array_i;
            state_array_o[2] = (round_config_i) ? state_array_i[2] ^ ConstAddLUT[rnd]
                                                : state_array_i[2] ^ ConstAddLUT[rnd + 4];

            return state_array_o;
        end

    endfunction


    // ----------------------------------------------------------
    // Substitution Layer Simulation
    // ----------------------------------------------------------

    //This is meant to be the expected output, we can use to compare
    //the results from sbox_eq function to our actual implementation substitution_layer.sv
    function automatic ascon_state_t substitution(
        input ascon_state_t x
    );

        ascon_state_t y;
        begin
            for(int j =0; j < WORD_WIDTH; j++) begin
                y[0][j] = (x[4][j] & x[1][j]) ^ x[3][j]
                        ^ (x[2][j] & x[1][j]) ^ x[2][j]
                        ^ (x[1][j] & x[0][j]) ^ x[1][j]
                        ^ x[0][j];

                y[1][j] = x[4][j] ^ (x[3][j] & x[2][j])
                        ^ (x[3][j] & x[1][j]) ^ x[3][j]
                        ^ (x[2][j] & x[1][j]) ^ x[2][j]
                        ^ x[1][j]^ x[0][j];

                y[2][j] = (x[4][j] & x[3][j]) ^ x[4][j] ^ x[2][j] ^ x[1][j] ^ 1'b1;

                y[3][j] = (x[4][j] & x[0][j]) ^ x[4][j]
                        ^ (x[3][j] & x[0][j]) ^ x[3][j]
                        ^ x[2][j] ^ x[1][j]   ^ x[0][j];

                y[4][j] = (x[4][j] & x[1][j]) ^ x[4][j] ^ x[3][j] ^ (x[1][j] & x[0][j]) ^ x[1][j];
            end

            return y;
        end
    endfunction

    // ----------------------------------------------------------
    // Diffution Layer Simulation
    // ----------------------------------------------------------

    // reference model: Right Circular Rotation (ROR). The corrcet behaviour of the Layer
    function automatic ascon_word_t ror64(input ascon_word_t data, input int shift);
        return (data >> shift) | (data << (64 - shift));
    endfunction

    // Compute expected output using the Ascon Sigma functions
    function automatic ascon_state_t diffution(
        input  ascon_state_t in_state
    );
        int r_a [5]; //rotation a
        int r_b [5]; //rotation b
        ascon_state_t out_state;

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
            out_state[i] = in_state[i] ^ ror64(in_state[i], r_a[i]) ^ ror64(in_state[i], r_b[i]);
        end

        return out_state;
    endfunction

    // ----------------------------------------------------------
    // Ascon Core Permutations Simulation
    // ----------------------------------------------------------

    function automatic ascon_state_t ascon_perm(
        input logic round_config_i,
        input ascon_state_t state_i
    );

        rnd_t rnd = round_config_i ? 4'd12: 4'd8;
        ascon_state_t state_o = state_i;
        for(int rnd_i = 0; rnd_i < rnd; rnd_i++) begin
            state_o = addition(rnd_i, round_config_i, state_o);
            state_o = substitution(state_o);
            state_o = diffution(state_o);
        end

        return state_o;

    endfunction

    // ----------------------------------------------------------
    // Utils and Helper Functions
    // ----------------------------------------------------------

    // Creates a random round number to aid in verifying correctness of hardware.
    task automatic rand_rnd(output rnd_t test_rnd);
        test_rnd = rnd_t'($urandom_range(0, 12));
    endtask

    // Generates a random input state array.
    task automatic rand_array(output ascon_state_t test_array);
        for (int i = 0; i < NUM_WORDS; i++) begin
            test_array[i] = {$urandom(), $urandom()};
        end
    endtask

endpackage : permutations_sim_pkg
