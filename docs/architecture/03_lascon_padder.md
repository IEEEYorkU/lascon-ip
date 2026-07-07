# Lascon Padder Design Strategy

### 1. Overview and Purpose
The `lascon_padder` serves as a dedicated AXI4-Stream pre-processor (or "Framer") for the Lascon Cryptographic Accelerator.

Its primary purpose is to intercept raw, incoming variable-length data streams and dynamically apply the precise bit-level padding, rate-alignment, and endianness conversion rules defined in NIST SP 800-232. By handling these complex byte-level operations on the fly, the padder abstracts the formatting burden away from the downstream protocol state machines (`aead_fsm`, `hash_fsm`), allowing them to function as highly efficient, protocol-agnostic block counters.

---

### 2. Architectural Fit: Decoupling Formatting from Control
In this accelerator's "Decoupled Data/Control" architecture, the padder sits directly behind the top-level external AXI4-Stream slave ports, acting as a crucial pipeline stage before data is routed to the Lascon core or the top-level XOR unit.

* **Upstream Flow Control:** The padder directly drives `s_axis_tready_o`, giving it the authority to halt the external data source if it needs extra clock cycles to generate artificial padding words.
* **Downstream Flow Control:** The padder monitors `padded_tready_i` (driven by the active FSM) to know when its formatted output has been successfully consumed.
* **Handshake Sidebands:** The padder provides two auxiliary signals to the downstream FSMs:
  - `padded_tkeep_raw_o`: An unmodified copy of the original stream `s_axis_tkeep_i` used by the FSM to track precise payload boundaries (specifically needed for decryption state masking and masking raw AXI `m_axis_tkeep_o` output).
  - `padded_is_padding_o`: Driven high when the padder is generating and emitting artificial carry blocks, instructing the FSM to suppress AXI stream master output valid flags (`m_axis_tvalid_o = 1'b0`) during those beats.
* **Clean Datapath:** By the time data leaves the padder on the `padded_tdata_o` bus, it is mathematically complete and rate-aligned. The downstream FSMs never need to inspect `padded_tkeep_o` during standard absorption phases; they simply XOR the full 64-bit payload into the core.

---

### 3. Core Responsibilities & Logic Parsing
The padder routes and modifies incoming packets strictly based on their `TUSER` sideband signal, sorting them into five distinct processing categories:

#### A. Endianness Conversion (All Streams)
The external AXI4-Stream bus provides data in Little-Endian format, whereas the internal Ascon state expects Big-Endian format. The padder automatically swaps the byte order of all incoming words on the `padded_tdata_o` bus to align with the core's expectations.

#### B. The Ascon Padding Rule & Carry Blocks (`TUSER_AD`, `TUSER_PT`, `TUSER_MSG`, `TUSER_Z`)
When processing variable-length data groups (Associated Data, Plaintext, Hash Messages, and Customization Strings), the padder monitors the stream for the boundary marker (`s_axis_tlast_i == 1`).
* **Partial Final Word (`s_axis_tkeep_i != 8'hFF`):** The padder evaluates the byte-enables to find the last valid byte, appends the mandatory Ascon padding sequence (a single `1` bit followed by `0`s to fill the 64-bit word), and forces the output `padded_tkeep_o = 8'hFF`.
* **Full Final Word (`s_axis_tkeep_i == 8'hFF`):** The final word contains only message data. Since the `10...0` padding cannot fit in the word, the padder delays the downstream end-of-packet marker (`padded_tlast_o = 1'b0`) and generates a subsequent "spillover" carry block containing `64'h8000_0000_0000_0000` to hold the padding.

#### C. Rate Alignment & AEAD 128-bit Boundaries
Ascon-Hash256 operates on a 64-bit rate ($r=64$), perfectly matching the 64-bit AXI bus width. However, Ascon-AEAD128 operates on a 128-bit rate ($r=128$, requiring two 64-bit words per block). When in AEAD mode, the padder enforces 128-bit rate alignment:
* **Ends on Word 0 (First 64 bits):**
  - *If partial:* Word 0 receives the data + padding. The padder stalls upstream traffic (`s_axis_tready_o = 1'b0`) and inserts a zero-filler word (`64'h0000_0000_0000_0000`) as Word 1, asserting `padded_tlast_o = 1'b1` on Word 1.
  - *If full:* Word 0 contains only data. The padder stalls upstream traffic and inserts a padding word (`64'h8000_0000_0000_0000`) as Word 1, asserting `padded_tlast_o = 1'b1` on Word 1.
* **Ends on Word 1 (Second 64 bits):**
  - *If partial:* Word 1 receives the data + padding. The block is complete, so `padded_tlast_o` is asserted immediately.
  - *If full:* Word 1 contains only data. The padder stalls upstream traffic and generates a new two-word block containing the padding: Word 0 gets `64'h8000_0000_0000_0000` and Word 1 gets `64'h0000_0000_0000_0000` (with `padded_tlast_o = 1'b1` on Word 1).

#### D. The Decryption Exception (`TUSER_CT`)
Ciphertext undergoes highly specialized handling during decryption.
* **Action:** The padder enforces a STRICT PASS-THROUGH. It does not append the $10...0$ bit sequence, and it passes the raw `s_axis_tkeep_i` byte-enables directly to the output.
* **Why?** During decryption, the fractional Ciphertext is required to overwrite the state precisely up to the $\ell$ boundary, while the padding bits are XORed into the remaining invalid byte positions. The `aead_fsm` requires the unmodified `TKEEP` signal to accurately pinpoint this boundary and manually execute the state split without corrupting the Plaintext output.

#### E. Strict Pass-Through Group (`TUSER_KEY`, `TUSER_NONCE`, `TUSER_TAG`)
Fixed-length cryptographic parameters are passed straight through the module unmodified. `TLAST` and `TKEEP` signals are passed transparently, as these inputs do not participate in standard sponge absorption padding.
