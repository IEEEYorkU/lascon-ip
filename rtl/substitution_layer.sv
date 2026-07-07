/*
 * Module Name: substitution_layer
 * Author(s): Arthur Sabadini, Kevin Duong
 * Description: The substitution layer applies a 5-bit nonlinear S-box in bit-sliced form across the entire state.
 *              This layer provides the "confusion" property to secure the state against linear analysis.
 * Ref: NIST SP 800-232
 */

`timescale 1ns / 1ps

import lascon_pkg::*;

module substitution_layer (
    input   ascon_state_t   state_array_i,
    output  ascon_state_t   state_array_o
);

    // ----------------------------------------------------------------------
    // S-box Look-Up Table (LUT)
    // ----------------------------------------------------------------------
    // See NIST SP 800-232 Section 3.3 Table 6
    localparam logic [NUM_WORDS-1:0] Sbox [32] = '{
        5'h4, 5'hb, 5'h1f, 5'h14, 5'h1a, 5'h15, 5'h9, 5'h2,
        5'h1b, 5'h5, 5'h8, 5'h12, 5'h1d, 5'h3, 5'h6, 5'h1c,
        5'h1e, 5'h13, 5'h7, 5'he, 5'h0, 5'hd, 5'h11, 5'h18,
        5'h10, 5'hc, 5'h1, 5'h19, 5'h16, 5'ha, 5'hf, 5'h17
    };

    // ----------------------------------------------------------------------
    // Parallel S-box Application
    // ----------------------------------------------------------------------
    genvar j;
    generate
        for (j = 0; j < WORD_WIDTH; j++) begin : gen_sbox_loop
            // Note that concatenation is needed here. As the
            // input of the Sbox LUT must be a number.
            assign {
                state_array_o[0][j],
                state_array_o[1][j],
                state_array_o[2][j],
                state_array_o[3][j],
                state_array_o[4][j]
            } = Sbox[{
                state_array_i[0][j],
                state_array_i[1][j],
                state_array_i[2][j],
                state_array_i[3][j],
                state_array_i[4][j]
            }];
        end
    endgenerate

endmodule
