# AEAD FSM Control Design Strategy

### 1. Overview and Purpose
The `aead_fsm` is the protocol orchestrator (or "The Brain") for the Lascon-AEAD128 Authenticated Encryption and Decryption accelerator.

This module implements Algorithm 3 (Authenticated Encryption) and Algorithm 4 (Authenticated Decryption) as defined in NIST SP 800-232. It is responsible for coordinating all cryptographic phases in the AEAD lifecycle, from initialization and processing associated data (AD), through plaintext/ciphertext encryption, to final tag generation and verification.

---

### 2. Architectural Fit: Pure Protocol Sequencer
In keeping with the "Decoupled Data/Control" philosophy of the accelerator, this FSM is designed as a stateless control-path orchestrator.

* **Zero Mathematical Knowledge:** The FSM possesses no knowledge of the mathematical internals of the Ascon permutation. It relies entirely on the `lascon_core` module to execute the permutation rounds.
* **Delegated Formatting:** It communicates with the outside world exclusively through the AXI4-Stream protocol via the `lascon_padder`. All byte-level padding and rate-alignment concerns are fully delegated to the padder, allowing this FSM to operate purely and efficiently at the 64-bit block level.

---

### 3. Operational Phases and Features
The FSM transitions through highly specific protocol phases, managing a split-control state machine built across 11 architectural states:

#### A. Initialization
The FSM orchestrates the loading of the 128-bit Key and 128-bit Nonce alongside the AEAD128 Initialization Vector (IV). It triggers the initial 12-round permutation and subsequently XORs the Key into state words `S3` and `S4` to establish the starting cryptographic state.

#### B. Associated Data (AD) Processing
The FSM absorbs variable-length Associated Data blocks. Following the final AD block, it asserts the mandatory Domain Separation bit into the state (XORing a `1` into `S4`) to securely separate the AD phase from the payload phase.

#### C. Simultaneous Data Transform and Output
During the Plaintext (`ST_PT_IN`) and Ciphertext (`ST_CT_IN`) processing phases, the FSM performs three operations in a single clock cycle:
1. Reads the current state word from the core.
2. Computes the transformed output (Ciphertext or Plaintext).
3. Writes the updated state back to the core while simultaneously driving the AXI Master interface.

To ensure compliance with variable-length AXI4-Stream inputs:
- **Output Suppression (`ST_PT_IN`):** The FSM uses the `padded_is_padding_i` handshake signal to suppress outputting ciphertext valid flags (`m_axis_tvalid_o = 1'b0`) during synthetic padding cycles.
- **Decryption Masking (`ST_CT_IN`):** Since decryption requires overwriting state bytes with Ciphertext while XORing padding into the rest, the FSM performs a byte-wise masked write. It uses `padded_tkeep_raw_i` to select which bytes of `S0`/`S1` receive the incoming CT, and which bytes are XORed with the `0x80` padding bit.
- **Raw TKEEP Propagation:** In both phases, `m_axis_tkeep_o` propagates the raw `padded_tkeep_raw_i` instead of the padded `padded_tkeep_i` so that downstream receivers see the exact byte lengths.

#### D. Critical Spec Compliance & Finalization
Per NIST SP 800-232, the final Plaintext or Ciphertext block **does not** trigger a standard permutation. The FSM strictly enforces this by bypassing the standard permutation state for the last block, moving directly into the `ST_TAG_INIT` phase where the Key is XORed into `S3` and `S4` before the final 12-round permutation. Following the final permutation, the Key is XORed into `S3` and `S4` once more to generate the authentication tag.

#### E. Tag Generation and Verification
* **Encryption Mode:** The FSM streams out the computed tag words (`S3` and `S4`) to authenticate the message.
* **Decryption Mode:** The FSM latches the incoming tag words from the receiver and performs a secure, two-cycle combinational comparison against the internally computed `S3` and `S4` registers. It asserts a `tag_fail_o` flag if the authentication check fails.

---

### 4. Shared Permutation State (`ST_PERM`)
To save logic area, the FSM reuses a single `ST_PERM` state across all four distinct permutation phases (Initialization, AD, Data, and Finalization). It utilizes a context register (`perm_ctx_r`) to record which phase triggered the permutation, ensuring the FSM asserts the correct round count (12 vs. 8 rounds) and safely returns to the correct operational loop upon completion.
