# Lascon Hardware Variants

This document details the different hardware variants supported by the Lascon accelerator and provides a scalable template for adding future implementations.

## 1. Introduction

The Lascon accelerator repository follows a **"Single-Source Parameterized Architecture"** philosophy. To support different targets (like standard FPGAs, ASICs, or highly constrained environments like Tiny Tapeout), we avoid duplicating source files (which creates a massive maintenance burden).

Instead, we use the SystemVerilog parameter `LASCON_VARIANT`. By passing this parameter down from the top-level wrappers through to modules like `lascon_core.sv`, we can use `generate` blocks to selectively instantiate different logic and architectural strategies. This allows the same shared underlying files to compile into radically different hardware depending on the variant parameter chosen.

---

## 2. Adding a New Variant (Template Guide)

As the project grows, you may need to implement new architectural strategies (e.g., a fully unrolled, high-throughput pipeline). Follow these steps to scale the system:

1. **Define the Variant ID:** Claim the next available integer (e.g., `LASCON_VARIANT = 2`). Add its documentation to this file using the template in Section 4.
2. **Implement RTL Logic:** Use `generate if (LASCON_VARIANT == 2)` inside shared modules (like `lascon_core.sv` or the substitution layers) to write your new architectural logic alongside the existing code.
3. **Create the Wrapper:** Create a thin top-level wrapper in `rtl/` (e.g., `lascon_top_unrolled.sv`) that instantiates `lascon_top` and passes down the new parameter: `#( .LASCON_VARIANT(2) )`.
4. **Create the Testbench:** Duplicate the integration testbench into `tb/` (e.g., `lascon_top_unrolled_tb.sv`) and instantiate your new wrapper.
5. **Update Infrastructure:**
   - Add your new wrapper (e.g., `rtl/lascon_top_unrolled.sv`) to the `rtl.f` filelist, placing it *above* the baseline `lascon_top.sv` to keep the baseline as the default.
   - Add your new wrapper name to the `top_modules` list in `.github/workflows/pr.yml` to enable automatic CI matrix synthesis for your new variant.

---

## 3. Variant Documentation Template

*(Use this template when documenting new variants in Section 3)*

```markdown
### Variant [ID]: [Name] (`LASCON_VARIANT = [ID]`)
- **Top-Level Wrapper:** `lascon_top_[name].sv`
- **Description:** [Brief description of the variant's purpose]
- **Characteristics:** [Key trade-offs: Area, Power, Latency, Throughput. Mention architectural changes like unfolding, pipelining, or serialization.]
```

## 4. Available Variants

### Variant 0: Baseline Architecture (`LASCON_VARIANT = 0`)
- **Top-Level Wrapper:** `lascon_top.sv`
- **Description:** The default, balanced implementation of the Lascon accelerator.
- **Characteristics:** This is not explicitly a "high performance" variant, but rather a balanced approach that completes a single round of the permutation per clock cycle (not unfolded/unrolled). It provides solid throughput and area efficiency for standard FPGA and ASIC targets.

### Variant 1: Tiny Tapeout / Area-Optimized (`LASCON_VARIANT = 1`)
- **Top-Level Wrapper:** `lascon_top_tt.sv`
- **Description:** A heavily area-optimized implementation tailored for the Tiny Tapeout project or extremely resource-constrained environments.
- **Characteristics:** Achieves a significantly smaller silicon footprint, trading off clock cycles or throughput to save logical gates.

---
