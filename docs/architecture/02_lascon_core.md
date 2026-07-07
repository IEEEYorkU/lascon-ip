# Lascon Core Design Strategy

### 1. Design Philosophy: "The Dumb Slave"
The guiding principle for this Lascon Core is **Decoupling**. We separate cryptographic mathematics from protocol logic.
* **Core Responsibility (The "Muscle"):** The Core is strictly a "Permutation Engine" and "State Register File". It knows how to store 320 bits and how to run the mathematical permutations for a specific number of rounds. It does **not** know what "Encryption" or "Hashing" is.
* **Controller Responsibility (The "Brain"):** All protocol-specific logic—XORing input data for absorption, extracting ciphertext, padding messages, and managing modes (AEAD vs. Hash)—is moved **out** of the Core and managed by the Controller.
* **Solved Problem:** This architecture elegantly solves the **Decryption Conflict** (where the state update differs from the output generation) because the Controller handles the XOR logic externally, treating the Core as a simple memory unit.

---

### 2. Module Interface (I/O)
This interface minimizes routing congestion by using a narrow 64-bit data path, matching the word size defined in the standard.

| Signal Name | Direction | Width | Purpose |
| :--- | :--- | :--- | :--- |
| **`clk`** | Input | 1 | System clock |
| **`rst`** | Input | 1 | **Global Reset.** Only used for power-on reset. (Standard "clearing" is done by overwriting state with IVs) |
| **`start_perm_i`** | Input | 1 | **Trigger.** A high pulse starts the permutation engine. |
| **`round_config_i`** | Input | 1 | **Configuration.** Selects the number of rounds to run: `1` starts the round counter at 0 (runs rounds 0 to 11, total 12 rounds / $p^{12}$), while `0` starts it at 4 (runs rounds 4 to 11, total 8 rounds / $p^8$). |
| **`write_en_i`** | Input | 1 | **Write Enable.** When high, writes `data_i` into the word selected by `word_sel_i`. |
| **`word_sel_i`** | Input | 3 | **Address Selector.** Selects which of the five state words (S0:S4) to write to or read from. |
| **`data_i`** | Input | 64 | **Input Data.** The 64-bit value to be written *directly* into the selected state word, overwriting its current value. Note that the core does not perform internal XORing. |
| **`data_o`** | Output | 64 | **Output Data.** Continuously outputs the current value of the state word selected by `word_sel_i`. |
| **`ready_o`** | Output | 1 | **Completion/Idle Status.** High when the Core is in the IDLE state and waiting for commands. Low when a permutation is actively running. |

*(Note: The `xor_en_i` signal was present in earlier architectural designs but has been completely removed in the final RTL implementation to keep the core strictly decoupled from XOR logic.)*

---

### 3. Summary of Operation Flow
The Controller interacts with this core in three distinct "Primitive Operations":
1. **Load/Overwrite (Initialization):** The Controller sets `word_sel_i` to 0..4, sets `data_i` with the IV, Key, or Nonce, and asserts `write_en_i` to load them sequentially.
2. **Permute (Round Function):** The Controller configures the rounds using `round_config_i` (1 for $p^{12}$, 0 for $p^8$) and pulses `start_perm_i`. It then waits for `ready_o` to assert.
3. **Absorb/Extract (Data Processing):**
   * **Read:** The Controller selects the desired lane via `word_sel_i` and reads the state word from `data_o`.
   * **Write/XOR:** The Controller computes the XOR externally (e.g., using the top-level `xor64` module) and writes the result back into the core state by asserting `write_en_i` with the XORed result on `data_i`.
