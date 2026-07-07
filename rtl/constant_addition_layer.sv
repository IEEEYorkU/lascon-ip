/*
 * Module Name: constant_addition_layer
 * Author(s): Sasha Calmels, Kiet Le, Patrick De Leo
 * Description: Implements the p_c (Constant Addition) layer of the Ascon
 *              permutation. It XORs a round-dependent 8-bit constant into the
 *              64-bit word x2 of the Ascon state to ensure round asymmetry.
 * Ref: NIST SP 800-232
 */

`timescale 1ns / 1ps

import lascon_pkg::*;

module constant_addition_layer (
    input   rnd_t           rnd_i,
    input   ascon_state_t   state_array_i,
    output  ascon_state_t   state_array_o
);

    // 12-entry LUT, each entry is 8 bit round constant
    localparam logic [7:0] AsconRcLut [12] = '{
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

    always_comb begin
        state_array_o = state_array_i;
        state_array_o[2] = state_array_i[2] ^ AsconRcLut[rnd_i];
    end

endmodule
