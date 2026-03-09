import ascon_pkg: :*;

/*
I finished Initialization, Associated data, plaintext
there are still Finalization and tag generation, signal completion or authentication failure
and combinational section for translates state into ouput signal
(when fsm moves to new states, these signals update instantly in the same cycles)
*/
/* 
Need to add aead_state_t in pkg, 
Need this or we can put these def in ascon_ctrl and ascon_datapath 
This aead_state help to carry step from ctrl to datapath 

*/
/*  
State encode

init: 9 state 
idle -> init_s0-> init_s1, init_s2, init_s3, init_s4 -> init_perm
init_kx3-> init_kx4


ad: 5 state 
Check -> xor0 -> xor 1 -> perm -> dom 

data: 10 state 
read_s0 -> read_s1-> xor0 -> xor1 -> out0-> out1 -> wr1-> perm-> check 

fin: 5 state 
kx2 -> kx3 -> perm -> read_3-> read_4 

end: 2 state 
done, error 

total: 31 state 
*/


// fsm state type
// aead_state_t is not in ascon_pkg.sv so i defined locally here.
// we need to copy this typedef into ascon_datapath.sv (state_i input).

/*typedef enum logic [4:0] {
    ST_IDLE,
    // ── Init ──────────────────────────────────────────────────────────────
    ST_INIT_S0,     // write IV        → S0
    ST_INIT_S1,     // write K[127:64] → S1
    ST_INIT_S2,     // write K[63:0]   → S2
    ST_INIT_S3,     // write N[127:64] → S3
    ST_INIT_S4,     // write N[63:0]   → S4
    ST_INIT_PERM,   // wait p[12] · 12 cycles
    ST_INIT_KX3,    // S3 ^= K[127:64]
    ST_INIT_KX4,    // S4 ^= K[63:0]
    // ── Associated Data ───────────────────────────────────────────────────
    ST_AD_CHECK,    // has_adata_i ?
    ST_AD_XOR0,     // S0 ^= Ai[127:64]
    ST_AD_XOR1,     // S1 ^= Ai[63:0]
    ST_AD_PERM,     // wait p[8] · 8 cycles
    ST_AD_DOM,      // S4 ^= DOMAIN_SEP
    // ── Data ──────────────────────────────────────────────────────────────
    ST_DAT_RD0,     // dec: read S0 → sread_r[0]
    ST_DAT_RD1,     // dec: read S1 → sread_r[1]
    ST_DAT_XOR0,    // enc: S0 ^= Pi[127:64]
    ST_DAT_XOR1,    // enc: S1 ^= Pi[63:0]  · latch is_last_r
    ST_DAT_OUT0,    // enc: read S0 → Ci[127:64]
    ST_DAT_OUT1,    // enc: read S1 → Ci[63:0]  · data_valid_o
    ST_DAT_WR0,     // dec: S0 = Ci[127:64]
    ST_DAT_WR1,     // dec: S1 = Ci[63:0]        · data_valid_o
    ST_DAT_PERM,    // wait p[8] · 8 cycles (shared ENC+DEC)
    ST_DAT_CHECK,   // is_last_r → FIN / else loop
    // ── Finalization ──────────────────────────────────────────────────────
    ST_FIN_KX2,     // S2 ^= K[127:64]
    ST_FIN_KX3,     // S3 ^= K[63:0]
    ST_FIN_PERM,    // wait p[12] · 12 cycles
    ST_FIN_RD3,     // read S3 → tag_r[0] = S3 ^ K[127:64]
    ST_FIN_RD4,     // read S4 → tag_r[1] = S4 ^ K[63:0]
    // ── End ───────────────────────────────────────────────────────────────
    ST_DONE,        // done_o = 1
    ST_ERROR        // auth_fail_o = 1 (DEC tag mismatch)
} aead_state_t;
*/

/*
P: Plaintext 
i: block index
Pi: i-th plaintext block 
Ci: i_th ciphertext block 
*/

module ascon_ctrl(
    //Clock, reset 
    input logic clk,
    input logic rst, 

    //Mode,Control
    input logic start_i,  // begin operation 
    input logic enc_dec_i, // enc=0, 1= dec 

    //Key,Nonce
    input ascon_word_t key_i [0:1] 
    input ascon_word_t nonce_i [0:1]

    // AD- AXI STREAM from padder unit 

    input ascon_word_t adata_i [0:1] // padded ad block
    input logic adata_valid_i // ad word ready 
    input logic adata_last_i // last ad blcok 
    input logic has_adada_i  // any ad exists 
    input axi_tuser_t adata_tuser_i // be tuser ad 

    // Plaintext / Ciphertext - AX4 stream from padder unit 

    input ascon_word_t ptext_i [0:1], // enc: plaintext padded, dec: ciphertext 
    input logic ptext_valid_i // block is ready 
    input logic ptext_last_i // last block 
    input logic ptext_tkeep_i 
    /*byte enable 
      8hFF for tuser_pt
      raw tkeep or tuser_ct                
    */ 

    input axi_tuser_t ptext_tuser_i

    //tag only for dec 
    input ascon_word_t tag_i [0:1]

    //from ascon_core 
    input ascon_word_t core_data_i //.read form 32bit state 
    input logic core_ready_i //permatatiom completed  
    
    // Output 
    output logic adata_ready_o // ctrl is ready to absord 
    output logic ptext_ready_o


    // to ascon_datapath 
    /*
    the single output replacing all direct MUX control signal 
    ascon_datapath decodes every hardware signal from state_o alone 
    */
    output aead_state_t state_o //need this, to carry the current state from ascon_ctrl to ascon_datapath. 

    //Data ouput 
    output ascon_word_t data_o  [0:1]
    output logic data_valid_o 

    //tag Output (enc only )
    output ascon_word_t tag_o  [0:1]
    output logic data_valid_o

    //tag output (dec only)
    output logic auth_ok_o    //tag matched 
    output logic auth_fail_o  //tag mismatch 

    //status 
    output logic busy_o //operation in progress
    output logic done_o //operation completed 


//Internal Registers 

aead_state_t state_r; 

logic mode_r; //enc =0, dec=1 

//Latched at ST_DAT_XOR1 (enc) or ST_DAT_WR1 (dec)
logic is_last_r; 

//dec only: S0/S1 snapshot befor state is overwritten with Ci 
//Plaintext recovery: Pi = sread_r ^ Ci
ascon_word_t sread_r [0:1];

//Output data buffer - Ci (enc) or Pi (dec)
ascon_word_t data_r[0:1];

//Authentication tag buffer: T = S3||S4 ^ k 
ascon_word_t tag_r [0:1];

//dec auth result - set at ST_FIN_RD4, read at ST_done/ ST_error  
logic auth_ok_r; 
logic auth_fail_r;

//Output Assignments 

// state forwarded to ascon_datapath - single source of truth 
assign state_o = state_r;

//register-backed output 
assign data_o = data_r; 
assign tag_o = tag_r;
assign auth_ok_o = auth_ok_r;
assign auth_fail_o = auth_fail_r;

/* Moore outputs (data_vaild_o, tag_valid_o, busy_o, done_o)
are driven by ascon_datapth as f(state_r) - not assigned here. 
*/


// Sequential - FSM transitions and register latching 

always_ff @(posedge clk or negedge rst) begin 
    if(!rst) begin 
        state_r     <= ST_IDLE;
        mode_r      <= 1'b0;
        is_last_r   <= 1'b0;
        sread_r[0]  <= '0;    
        sread_r[1]  <= '0;
        data_r[0]   <= '0;
        data_r[1]   <= '0;
        tag_r[0]    <= '0; 
        tage_r[1]   <= '0;
        auth_ok_r   <= 1'b0;
        auth_fail_r <= 1'b0;

    end 

    //IDLE -wait for start_i
    else begin 
        case(state_r)
        ST_IDLE: begin
            auth_ok_r   <= 1'b0;
            auth_fail_r <= 1'b0;
            if(start_i) begin 
                mode_r  <= enc_dec_i; // latch enc/dec at start 
                state_r <= ST_INIT_S0;
            end
        end
    //INIT - Load IV, K[1:0], N[1:0]
    ST_INIT_S0:     state_r     <= ST_INIT_S1;
    ST_INIT_S1:     state_r     <= ST_INIT_S2;
    ST_INIT_S2:     state_r     <= ST_INIT_S3;
    ST_INIT_S3:     state_r     <= ST_INIT_S4;
    ST_INIT_S4:     state_r     <= ST_INIT_PERM;

    //Wait for 12 cycles 
    ST_INIT_PERM: begin 
        if (core_ready_i)
        state_r     <= ST_INIT_KX3;
    end

    //XOR key back to s3, s4 
    ST_INIT_KX3:    state_r <= ST_INIT_KX4;
    ST_INIT_KX4:    state_r <= ST_AD_CHECK;


    // associated data absorption 

    ST_AD_CHECK: begin
        satge_r <= has_adata_i ? ST_AD_XOR0 : ST_AD_DOM;
    end

    //wait for padder unit
    ST_AD_XOR0: begin 
        if (adata_valid_i)
        state_r <= ST_AD_XOR1;
    end

    ST_AD_XOR1:     state_r <= ST_AD_PERM;

    //wait for p[8] - loop back if more AD blocks remain
    ST_AD_PERM: begin 
        if(core_ready_i)
        state_r <=  adata_last_i ? ST_AD_DOM : ST_AD_XOR0;
    end

    //Domain seperation - branch enc path /dec path 
    ST_AD_DOM: begin 
        state_r <= mode_r ? ST_DAT_RD0 : ST_AD_XOR0;
    end

    //DATA - dec path: read S0/S1 before overwrite
    // Must save state before Ci overwrites it 

    ST_DAT_RD0: begin 
        if(ptext_valid_i) begin 
            sread_r[0]  <= core_data_i;
            state_r     <= ST_DAT_RD1;
        end
    end


    ST_DAT_RD1: begin 
        if(ptext_valid_i) begin 
            sread_r[1]  <= core_data_i;
            state_r     <= ST_DAT_WR0;
        end
    end

    //Data_enc path: XOR Pi into state

    ST_DAT_XOR0: begin 
        if (ptext_valid_i)
        state_r <= ST_DAT_XOR1;
    end
    ST_AD_XOR1:begin 
        is_last_r   <= ptext_last_i; // latch before permutation 
        state_r     <= ST_DAT_OUT0;  // ptext_last_i may change during the loop p[8]
    end

    //enc: read Ci back from state after XOR 
    ST_DAT_OUT0: begin 
        data_r[0]   <= core_data_i // latch Ci[1] 
        state_r     <= ST_DAT_OUT1;
    end

    ST_DAT_OUT1: begin 
        data_r[1]   <= core_data_i; //latch Ci[0] 
        state_r     <= ST_DAT_PERM; //data_valid_o asserted here by ascon_datatpath 
    end

    //data-perm: shared enc and dec path 
    // wait for 8 cycles 
    ST_DAT_PERM: begin 
        if(core_ready_i)
        state_r <= ST_AD_CHECK;
    end

    //Data check: loop or transition to finalization 

    ST_DAT_CHECK: begin 
        If(is_last_r)
        state_r     <= ST_FIN_KX2   //done->finalize 
        else 
        state_r     <= mode_r ? ST_DAT_RD0 : ST_DAT_XOR0 //more block for dec or more block for enc 
    end

    //Finalization: XOR key, run 12 loop, extract tag 

    //End: signal completion or authentication failure 

    // Combinational 

    


    end    



endmodule
)
