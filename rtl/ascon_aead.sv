import ascon_pkg::*;


module ascon_aead(
    //Clock, reset 
    input logic clk,
    input logic rst, 
==========================================================================
    //Mode,Control
==========================================================================

    input ascon_mode_t mode_i,  //Mode: ENC or DEC 
    input logic        start_i,        
    output logic       busy_o,     
    output logic       done_o, 
    output logic       tag_fail_o, //Decryption tag check fails 

    //Interface 
    input  logic                ascon_ready_i, 
    output logic                start_perm_o, 
    output logic                round_config_o,
    output logic     [2:0]      word_sel_o,  // target state word address S0,S1,.., S4
    output ascon_word_t         data_o,
    output logic                write_en_o, 
    output logic                xor_en_o,
    output data_sel_t           in_data_sel_o,  //Mux select for core data_i source 
    input  ascon_word_t         core_data_i,
    

    // AD- AXI STREAM from padder unit 

    input ascon_word_t     padded_tdata_i, //Pre-processed 
    input logic [7:0]      padded_tkeep_i, //Pass - through for CT 
    input axit_tiser_t     padded_tuser_i, //Packet type
    input logic            padded_tlast_i, //last word in the message 
    input logic            padded_tvalid_i
    output logic            padded_tready_o, 
    

    // Plaintext / Ciphertext - AX4 stream from padder unit 
    output ascon_word_t     m_axis_tdata_o, 
    output logic [7:0]      m_axis_tkeep_o,
    output logic [2:0]      m_axis_tuser_o, 
    output logic            m_axis_tlast_o, 
    output logic            m_axis_tvalid_o, 
    input logic             m_ais_tready_i, 

    localparam ascon_word_t AEAD128_IV = 64'h00001000808c0001; // IV <-  0x00001000808c0001 
    localparam ascon_word_t DSEP       = 64'h0000000000000001; // Domain separation: S ← S ⊕ (0^319 ∥ 1), only s4 change, s0,s1,s2,s3 are full of 0
    localparam logic ROUND_PA = 1'b1;  //12 round permutaiton 
    localparam logic ROUNF_PB = 1'b0;  //8 round permuation 


    typedef enum logic [3:0] { 
        ST_IDLE     = 4'd0,
        ST_INIT     = 4'd1,
        ST_PERM     = 4'd2,
        ST_AD       = 4'd3,
        ST_PT_IN    = 4'd4,
        ST_CT_IN    = 4'd5,
        ST_TAG_INIT = 4'd6,
        ST_ENC_TAG  = 4'd7,
        ST_DEC_TAG  = 4'd8,
        ST_VERIFY   = 4'd9,
        ST_DONE     = 4'd10,
        //ST_ERROR    = 4'd11 
    } state_t;

    typedef enum logic [1:0] { 
        CTX_INIT  = 2'd0, //12 round permutation after initialization loading
        CTX_AD    = 2'd1, // 8 round permutation after each AD BLock
        CTX_DATA  = 2'd2, // 8 round permutation after each non-final PT/Ct block 
        CTX_FINAL = 2'd3  // 8 round permutation during finalization 
    } perm_ctx_t;

==========================================================================
    // Register 
==========================================================================

    state_t    state_r; 
    perm_ctx_t perm_ctx_r; 

    //INIT Phase: tracks which word is being loaded into the core 
    logic [2:0] init_cnt_r; 

    //PERM phase management 
    logic        perm_started_r; 
    logic        post_perm_active_r; 
    logic [1:0]  post_perm_cnt_r; 

    //AD absorption 
    logic    ad_word_r; 
    logic    ad_last_seen_r; 

    //PT/CT absorption 
    logic    dat_word_r; 
    logic    dat_last_seen_r; 

    //Finalization
    logic [1:0] tag_init_cnt_r; //0=K→S1 XOR, 1=K→S2 XOR, 2=transition to PERM

    //Tag output(enc) and tag receive (dexc) 
    logic tag_cnt_r;  //0=S3/T_word0, 1=S4/T_word1 

    // Tag verification 
    logic [1:0] verify_cnt_r;  // 0=compare S3, 1=compare S4, 2=done
    
    // Stored key captured during INIT 
    ascon_word_t key_r[0:1]; 
    
    //dec only: received tag words 
    ascon_word_t rx_tag_r[0:1]; 

    //tag match result 
    logic tag_ok_r; 
==========================================================================
    //Combinational Helpers 
==========================================================================
    
    logic is_enc;
    assign is_enc = (mode_i == MODE_AEAD_ENC); 
    
    // Padded handshake: 
    logic phs;
    assign phs = padded_tvalid_i && padded_tready_o;
    
    //Permutation complete
    logic perm_done;
    assign perm_done = perm_started_r && ascon_ready_i; 

    //Max post-per counter value 
    logic [1:0] pp_max; 
    always_comb begin 
        case (perm_ctx_r) 
            CTX_INIT:  pp_max = 2'd1;
            CTX_AD:    pp_max = 2'd0;
            CTX_FINAL: pp_max = 2'd1;
            default:   pp_max = 2'd0;
        endcase
    end

    logic pp_done; 
    assign pp_done = post_perm_active_r && (post_perm_cnt_r == pp_max);
        

    
==========================================================================
    // Sequential - FSM transitions and register latching 
==========================================================================
    
    state_t next_state; 
    always_ff @(posedge clk or posedge rst) begin 
        if(!rst) state_r <= ST_IDLE; 
        else state_r <=  next_state;
    end

==========================================================================
    // NEXT-STATE Logic 
==========================================================================
    always_comb begin
    
    
    
    end
    
endmodule
