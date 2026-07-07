/*
 * Module Name: linear_diffusion_layer
 * Author(s): Artin Kiany, Tirth Patel
 * Description: XORs each 64-bit word of the 320-bit state with two  rotated versions of
 *              itself to provide intra-word bit diffusion using only rotations and XORs.
 * Ref: NIST SP 800-232
 */

`timescale 1ns / 1ps

import lascon_pkg::*;

module linear_diffusion_layer(
    input  ascon_state_t state_array_i,
    output ascon_state_t state_array_o
);

    ascon_word_t s0, s1, s2, s3, s4;

    assign s0 = state_array_i[0];
    assign s1 = state_array_i[1];
    assign s2 = state_array_i[2];
    assign s3 = state_array_i[3];
    assign s4 = state_array_i[4];

    ascon_word_t s0_d, s1_d, s2_d, s3_d, s4_d;

    always_comb begin
        // Rotate-right implemented via logical shifts
        s0_d = s0 ^ ((s0 >> 19) | (s0 << ( WORD_WIDTH - 19))) ^
                    ((s0 >> 28) | (s0 << ( WORD_WIDTH - 28)));
        s1_d = s1 ^ ((s1 >> 61) | (s1 << ( WORD_WIDTH - 61))) ^
                    ((s1 >> 39) | (s1 << ( WORD_WIDTH - 39)));
        s2_d = s2 ^ ((s2 >> 1 ) | (s2 << ( WORD_WIDTH - 1 ))) ^
                    ((s2 >> 6 ) | (s2 << ( WORD_WIDTH - 6 )));
        s3_d = s3 ^ ((s3 >> 10) | (s3 << ( WORD_WIDTH - 10))) ^
                    ((s3 >> 17) | (s3 << ( WORD_WIDTH - 17)));
        s4_d = s4 ^ ((s4 >> 7 ) | (s4 << ( WORD_WIDTH - 7 ))) ^
                    ((s4 >> 41) | (s4 << ( WORD_WIDTH - 41)));
    end

    // Preserve Ascon word ordering: index 0 = S0, index 4 = S4
    assign state_array_o[0] = s0_d;
    assign state_array_o[1] = s1_d;
    assign state_array_o[2] = s2_d;
    assign state_array_o[3] = s3_d;
    assign state_array_o[4] = s4_d;

endmodule
