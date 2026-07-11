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

    (* keep *) logic [7:0] round_const;
    assign round_const = {~rnd_i, rnd_i};

    always_comb begin
        state_array_o = state_array_i;
        state_array_o[2][7:0] = state_array_i[2][7:0] ^ round_const;
    end

endmodule
