# HASH FSM Control Design Strategy

### 1. Overview and Purpose
The `hash_fsm` (Hash Finite State Machine) is a dedicated control-path orchestrator for the Ascon cryptographic accelerator. It natively supports **Ascon-Hash256**, **Ascon-XOF128**, and **Ascon-CXOF128**.

Its primary purpose is to manage the AXI4-Stream protocol handshaking, track the sponge construction phases (Initialization, Absorbing, and Squeezing), and issue precise cycle-by-cycle control signals to the centralized `ascon_core` and top-level datapath multiplexers.

---

### 2. Architectural Fit: The "Decoupled Data/Control" Paradigm
In this accelerator's architecture, the `hash_fsm` operates strictly as the "Brains" for hashing operations, leaving the "Muscle" (mathematics) to the `ascon_core` and the bit-level formatting to the `ascon_padder`.

This decoupled philosophy manifests in several key ways:
* **Zero Padding Logic:** The FSM does not process raw byte-enables (`TKEEP`) or message data (`TDATA`). It only receives AXI-Stream handshake control signals (`padded_tvalid_i`, `padded_tlast_i`) and packet metadata (`padded_tuser_i`) from the Padder/Framer unit, while the 64-bit data stream (`padded_tdata`) is routed directly to the Core/XOR unit.
* **Externalized XOR:** During the absorbing phase, the FSM does not compute the internal `S0 <- S0 XOR M_i` operation. Instead, it asserts `xor_sel_o` and `core_in_data_sel_o` to route the padded AXI stream and the core's state through the top-level `xor64` unit.
* **Datapath Bypass (Squeezing):** During the squeezing phase, the FSM does not read data out of the core to pass it to the AXI Master bus. Instead, the top-level arbiter routes the core's output (`core_data_o`) directly to `m_axis_tdata` (with byte swapping applied). The FSM merely sets the correct word select address (`S0`) and manages the `tvalid`/`tready` handshake.

---

### 3. Operational Phases and Features
The FSM executes the hashing algorithms through three distinct phases:

#### A. Initialization
Upon receiving a `start_i` pulse, the FSM assesses the `mode_i` configuration. It drives the pre-computed 320-bit Initialization Vector (IV) specific to the chosen algorithm (Hash, XOF, or CXOF) onto the `data_o` bus sequentially. It writes this into the core (`S0`...`S4`) and triggers the initial 12-round permutation (`p^12`).

#### B. Absorbing Phase
The FSM continuously asserts `padded_tready_o` to pull in 64-bit message blocks.
* For each valid block, it routes the data through the top-level XOR into the `S0` register.
* The FSM triggers a `p^12` permutation after each valid block is absorbed. If the block arrives alongside `padded_tlast_i == 1` and is not a Customization String (`TUSER_Z`), it transitions the state machine from the Absorbing phase into the Squeezing phase.
* **CXOF Special Handling:** If the final byte of a customization string block is detected (`padded_tlast_i == 1` with `padded_tuser_i == TUSER_Z`), the FSM runs the `p^12` permutation but remains in the Absorbing phase to await the actual message.

#### C. Squeezing & Continuous XOF Mode
Because XOF (Extendable Output Function) algorithms can produce infinitely long digests, the `hash_fsm` supports two distinct squeezing methodologies, configurable via `xof_len_i`:
* **Fixed-Length Mode (`xof_len_i > 0`):** The FSM tracks the number of squeezed bytes. It continuously triggers 12-round permutations, outputting 64-bit blocks until the requested length is met, at which point it asserts `m_axis_tlast_o` and returns to IDLE.
* **Continuous / Rejection Sampling Mode (`xof_len_i == 0`):** The FSM enters an infinite squeeze loop. It squeezes a block, waits for the downstream AXI Slave to consume it, and generates the next block via intermediate permutations. This allows the host processor to perform rejection sampling. When the host manually asserts the `abort_i` control signal, the FSM asserts `m_axis_tlast_o` on the final output beat to properly terminate the AXI Stream packet before returning to IDLE.

---

### 4. Hardware Interfaces
* **Phase 1 CSR (Control/Status):** Basic pulse triggers (`start_i`, `abort_i`) and status flags (`busy_o`, `done_o`).
* **Core Control:** Direct lines to the Ascon core to set permutation rounds (`round_config_o`), select memory lanes (`word_sel_o`), and trigger permutations (`start_perm_o`).
* **AXI4-Stream Interfaces:** Completely standard, AXI-compliant handshake signals (`tvalid`, `tready`, `tlast`, `tuser`) connecting upstream to the Padder and downstream to the system datapath.
