# System Overview: Lascon Hardware Accelerator

## Introduction to NIST SP 800-232
This project is a SystemVerilog hardware accelerator for the **NIST SP 800-232 Standard: Ascon-Based Lightweight Cryptography Standards for Constrained Devices**.

Ascon is a family of cryptographic algorithms designed to provide efficient Authenticated Encryption with Associated Data (AEAD), hash functions, and extendable Output Functions (XOF). It was selected by NIST specifically for resource-constrained environments—such as Internet of Things (IoT) devices, embedded systems, and low-power sensors—where traditional standards like AES-GCM may be too resource-intensive or consume too much power.

In a real-world scenario, this hardware module operates as a dedicated cryptographic co-processor. A host microcontroller streams raw plaintext and keys into the accelerator via standard bus interfaces (like AXI4-Stream), and the accelerator securely encrypts and authenticates the data in hardware, saving the host CPU thousands of clock cycles and significantly reducing system power consumption.

---

## Architectural Design Strategy: The Decoupled Data/Control Paradigm

To maximize modularity and design clarity, the accelerator employs a strict **"Decoupled Data/Control"** strategy. This philosophy divides the architecture into four distinct, specialized components:

### 1. The Lascon Core (The "Muscle")
The `lascon_core` module is a protocol-agnostic cryptographic mathematical engine. It solely maintains the 320-bit state and executes the round permutations ($p_C$, $p_S$, and $p_L$). It does not possess any knowledge of padding rules, AXI handshaking, or high-level modes (AEAD vs. Hash); it simply executes rounds upon request and notifies controllers when it is ready.

### 2. The AXI4-Stream Padder (The "Framer")
The `lascon_padder` serves as a dedicated pre-processor. It intercepts raw incoming data from the outside world, converts Little-Endian data to Big-Endian, and applies the precise bit-level padding and rate-alignment rules defined by NIST SP 800-232. By handling byte-masking and multi-cycle padding carry blocks internally, it abstracts all formatting concerns, outputting a clean, rate-aligned 64-bit stream to the internal logic.

### 3. Protocol Controllers (The "Brains")
The high-level protocol FSMs (`aead_fsm` and `hash_fsm`) sequence the cryptographic algorithms. They manage standard AXI-stream flow control, track sponge construction phases (Initialization, Absorbing, and Squeezing), and issue cycle-by-cycle command signals to route data and trigger permutations. They remain entirely unburdened by low-level math or padding rules.

### 4. Top-Level Arbiter/Wrapper (The "Traffic Director")
The `lascon_top` module integrates all sub-modules. Based on the selected operating mode (`mode_i`), it multiplexes control wires, handshakes, and datapath routes between the active protocol controller and the shared hardware resources (the Padder, the Lascon Core, and the external `xor64` block).

---

## Summary of Benefits
By dividing concerns in this manner:
* **Decryption Conflict Solved:** The FSMs can coordinate state updates externally without forcing complex, multi-purpose logic inside the core state registers.
* **Ease of Verification:** Individual components (like the Padder or Core) can be isolated and verified against their specific requirements independently of the high-level state machines.
