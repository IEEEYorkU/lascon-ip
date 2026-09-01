# FPGA Bring-Up Strategy: PYNQ-Z2 Integration

This document outlines the strategy for integrating and verifying the Lascon cryptographic hardware accelerator on a Xilinx Zynq-7000 SoC (specifically, the PYNQ-Z2 development board). 

It is designed to onboard new contributors to the FPGA effort by explaining the current state of the hardware, the challenges of software-hardware co-design, and the exact roadmap for deployment.

---

## 1. Introduction & Goal
The ultimate goal of this FPGA bring-up is to verify our SystemVerilog accelerator against the official NIST SP 800-232 Known Answer Tests (KATs) at real hardware speeds. 

Instead of writing complex C drivers, we are utilizing the **PYNQ framework**. PYNQ runs a full Linux OS on the Zynq's ARM processor, allowing us to allocate memory buffers and interact with the FPGA fabric entirely through **Python scripts and Jupyter Notebooks**.

## 2. Current State of the Hardware
Our top-level module, `lascon_top.sv`, currently splits its interfaces into two categories:
1. **High-Speed Data (AXI4-Stream):** The `s_axis` and `m_axis` ports handle the streaming of Plaintext, Ciphertext, Keys, and Hashes perfectly. We will connect these directly to a Xilinx **AXI Direct Memory Access (DMA)** IP block, allowing Python to stream gigabytes of data into the hardware effortlessly.
2. **Control Signals (Discrete Wires):** The configuration and status of the accelerator are currently exposed as physical hardware wires:
   ```systemverilog
   input  logic        start_i,
   input  lascon_mode_t mode_i,
   output logic        busy_o,
   ```

## 3. The Challenge: Software to Hardware Communication
A Python script running on an ARM processor cannot physically toggle an individual wire like `start_i`. Processors communicate with hardware peripherals exclusively by writing to and reading from specific memory addresses (Memory-Mapped I/O). 

If we place `lascon_top.sv` onto the FPGA as-is, the ARM processor will have no way to start the accelerator or change its operating mode.

## 4. The Solution: The AXI4-Lite Control Wrapper
To bridge the gap between software and hardware, we will create a new SystemVerilog file named `rtl/lascon_axi_wrapper.sv`. 

This file will instantiate our existing `lascon_top` module and add a standard **AXI4-Lite Slave** interface. AXI-Lite is a lightweight bus protocol specifically designed for exposing control and status registers (CSRs) to a processor.

The wrapper will translate memory transactions from Python into hardware pulses and levels:
* **Write to `0x00` (Control Register):** 
  - Bit 0: Software writes a `1` to trigger a 1-clock-cycle pulse on `start_i`.
  - Bit 1: Software writes a `1` to trigger a 1-clock-cycle pulse on `abort_i`.
  - Bits 4:2: Software writes the `mode_i` selection (e.g., AEAD vs. Hash).
* **Write to `0x04` (XOF Length Register):** 
  - Drives the 32-bit `xof_len_i` configuration wire.
* **Read from `0x08` (Status Register):** 
  - Bit 0: Software reads this to see if the core is `busy_o`.
  - Bit 1: Software reads this to see if the core is `done_o`.
  - Bit 2: Software reads this to check for MAC authentication failure (`tag_fail_o`).

By implementing this wrapper, our Python script can simply execute `register_map.start = 1` to kick off the encryption.

## 5. Repository Structure
To keep the repository clean and prevent massive Vivado build logs from bloating the version control history, we will enforce strict `.gitignore` rules for Vivado artifacts (`.Xil`, `*.xpr`, `*.jou`, `*.runs/`).

All FPGA-specific integration files will be contained in a new directory:
```text
ascon-sp800-232-sv/
├── fpga/
│   └── pynq_z2/
│       ├── ip/            # Location for the packaged Vivado IP
│       ├── tcl/           # Tcl scripts to auto-regenerate the Block Design
│       ├── xdc/           # Board pin constraints (if required)
│       └── sw/            # PYNQ Python verification scripts and NIST vectors
```

## 6. Vivado IP Packaging
With the AXI-Lite wrapper written, the final integration step is to package the RTL into a standalone Vivado IP block:
1. We will use Vivado's **Create and Package New IP** wizard on the `rtl/` directory.
2. Vivado will automatically group our individual signals into standard AXI-Stream and AXI-Lite bus interfaces.
3. Once packaged, the Lascon accelerator can be dragged and dropped into a Vivado Block Design, allowing us to visually connect it to the ARM processor and DMA engine for final bitstream generation.
