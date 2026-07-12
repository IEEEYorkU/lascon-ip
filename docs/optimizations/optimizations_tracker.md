# Optimization Options Tracking

This document tracks potential hardware optimization proposals for the LASCON hardware accelerator. Each optimization option is documented below with its description, PPA (Performance, Power, Area) impact, required RTL/architectural changes, execution difficulty, and current status.

---

## Status Summary

| Status | Count |
| :--- | :---: |
| 🟢 **Completed** | 5 |
| 🟡 **In-Progress** | 0 |
| 🔵 **Pending** | 10 |
| 🔴 **Denied** | 3 |

---

## Optimization Template

To propose or track a new optimization, copy the markdown block below, append it to the [Optimizations Log](#optimizations-log) section, and fill in the details.

```markdown
### OPT-[ID]: [Title of Optimization]

> [!WARNING]  <!-- Optional: Use Alert box for critical status updates, e.g. Denied -->
> **Denied (YYYY-MM-DD):** [Reason for denial, e.g. Exceeded area budget]

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: YYYY-MM-DD*

#### Description
[Provide a clear description of the optimization and the core idea.]

#### PPA (Performance, Power, Area) Impact
- **Performance:** [e.g., Latency, throughput, frequency ($f_{max}$)]
- **Power:** [e.g., Dynamic power, static power]
- **Area:** [e.g., LUT/Register counts, memory blocks, overall gate count]

#### Required Changes
- [ ] Component A (e.g., `lascon_core`): [Details of change]
- [ ] Component B (e.g., `lascon_padder`): [Details of change]

#### Difficulty
- **Execution Difficulty:** Easy / Medium / Hard
- **Justification/Risks:** [Provide brief explanation of risk or design complexity]

#### Notes & Decisions
- **YYYY-MM-DD**: [Initial proposal notes or thoughts]
- **YYYY-MM-DD**: [Subsequent design meeting notes, review results, or denial reasoning]
```

---

## Optimizations Log

<!-- Append filled templates below this line -->

### OPT-1: Serialize the S-box (Substitution Layer)

#### Status
- [x] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-07*

#### Description
Replace the 64-wide parallel S-box (`generate` loop of 64 × 5→5 LUT instances in `substitution_layer`) with a smaller number of S-box instances that process a subset of bit-columns per clock cycle. The middle-ground approach targets ~8 S-box instances processing 8 columns/cycle, yielding ~8× area reduction in the S-box with 8 cycles per substitution step.

#### PPA (Performance, Power, Area) Impact
- **Performance:** Latency per round increases from 1 cycle to ~8 cycles (at 8-wide serialization). Total p¹² goes from 12 to ~96 cycles. Throughput reduced proportionally.
- **Power:** Significant dynamic power reduction — fewer gates switching per cycle.
- **Area:** ~8× reduction in substitution layer area (largest combinational block). Very high impact.

#### Required Changes
- [ ] `substitution_layer`: Replace 64-wide `generate` loop with parameterized width (e.g., 8) and add bit-column counter
- [ ] `lascon_core`: Add new sub-state for multi-cycle S-box processing; modify round FSM to wait for S-box completion
- [ ] `substitution_layer_tb`: Update to validate multi-cycle operation
- [ ] `lascon_core_tb`: Update cycle-count expectations

#### Difficulty
- **Execution Difficulty:** Medium
- **Justification/Risks:** Requires fundamental changes to the core FSM timing. All downstream integration tests must be updated. The `ready_o` handshake protocol remains unchanged, so higher-level FSMs should be unaffected.

#### Notes & Decisions
- **2026-07-07**: Proposed. Identified as the single largest area optimization opportunity. The middle-ground option (8-wide) offers a good area/performance balance. Under consideration.

---

### OPT-2: Fold the Permutation Round — Multi-Cycle per Round

> [!WARNING]
> **Denied (2026-07-07):** Does not align with design goals. Pipelining increases register count (area overhead) and the design does not need higher clock frequency.

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [x] **Denied**

*Last Updated: 2026-07-07*

#### Description
Pipeline the permutation round (p_C → p_S → p_L) into 2 or 3 clock stages to reduce the critical path and enable higher Fmax or voltage scaling.

#### PPA (Performance, Power, Area) Impact
- **Performance:** Enables higher Fmax through shorter critical path.
- **Power:** Potential for voltage scaling at lower Fmax targets.
- **Area:** Increases area due to additional pipeline registers (5 × 64-bit = 320 FFs per pipeline stage).

#### Required Changes
- N/A (Denied)

#### Difficulty
- **Execution Difficulty:** Medium
- **Justification/Risks:** Adds pipeline registers that increase area, contradicting the area-first priority.

#### Notes & Decisions
- **2026-07-07**: Denied. The design does not require higher clock frequency, and the additional pipeline registers would increase area — contrary to the project's area-first optimization priority.

---

### OPT-3: Replace S-box LUT with Boolean Logic

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [x] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-08*

#### Description
Replace the 32-entry × 5-bit S-box LUT array in `substitution_layer` with the equivalent Boolean equations from NIST SP 800-232 Section 3.3. The Boolean form uses ~5 XOR + 5 AND + 1 NOT per bit-slice, mapping directly to standard cells without relying on synthesis tool LUT inference.

#### PPA (Performance, Power, Area) Impact
- **Performance:** Negligible change — combinational depth is similar.
- **Power:** Minor reduction — fewer internal nodes toggling vs. LUT decoder trees.
- **Area:** Moderate reduction — predictable gate-level mapping vs. potentially bloated LUT inference.

#### Required Changes
- [x] `substitution_layer`: Replace `Sbox` LUT with Boolean equations implementing the Ascon S-box
- [x] Verify against `substitution_layer_tb` and `lascon_core_tb`

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Drop-in replacement. Existing testbenches should pass without modification since the functional behavior is identical.

#### Notes & Decisions
- **2026-07-07**: Approved for implementation. Testing in progress.
- **2026-07-08**: Completed implementation and verified using automated testbenches (`substitution_layer_tb`, `lascon_core_tb`, and `lascon_top_tb`) with ModelSim (`vsim`). All tests passed successfully.

---

### OPT-4: Eliminate Duplicate `swap_bytes` Function

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [x] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-09*

#### Description
The `swap_bytes` function is defined identically in both `lascon_padder` and `lascon_top`. Move it into `lascon_pkg` as a package-level function to eliminate duplication and improve maintainability.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None — byte reordering is pure routing (wire shuffle).
- **Power:** None.
- **Area:** None — zero synthesis impact.

#### Required Changes
- [x] `lascon_pkg`: Add `swap_bytes` function
- [x] `lascon_padder`: Remove local `swap_bytes`, use package version
- [x] `lascon_top`: Remove local `swap_bytes`, use package version

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Pure code hygiene refactor. No functional or PPA risk.

#### Notes & Decisions
- **2026-07-07**: Approved. Low-effort cleanup.
- **2026-07-09**: Completed implementation and verified using automated testbenches under Verilator. All tests passed.

---

### OPT-5: Gate the Inactive FSM (Clock or Data Gating)

#### Status
- [x] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-07*

#### Description
Both `aead_fsm` and `hash_fsm` are instantiated simultaneously in `lascon_top`. The inactive FSM's registers toggle on every clock edge, consuming unnecessary dynamic switching power. Gate the inactive FSM via RTL-level data gating (force `start_i = 0` and hold reset) or clock gating cells.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** Moderate-to-significant dynamic power reduction — eliminates all register toggling in the inactive FSM.
- **Area:** Minimal overhead (a few AND gates or one ICG cell).

#### Required Changes
- [ ] `lascon_top`: Add mode-based gating logic for `start_i` and/or `rst` to each FSM
- [ ] Optional: Insert clock-gating cells (technology-dependent)
- [ ] Integration test: Verify mode switching still works correctly after gating

#### Difficulty
- **Execution Difficulty:** Medium
- **Justification/Risks:** RTL-level data gating (Option A) is portable and low-risk. Clock gating (Option B) requires technology-specific cells. Must verify that gated FSMs return to a clean state when re-activated.

#### Notes & Decisions
- **2026-07-07**: Approved for pursuit. RTL-level data gating (Option A) preferred initially for portability.

---

### OPT-6: Reduce the `word_cnt` / `xof_len` Counter Widths

> [!WARNING]
> **Denied (2026-07-07):** Maintaining full 32-bit width for maximum flexibility in XOF output length.

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [x] **Denied**

*Last Updated: 2026-07-07*

#### Description
Reduce `xof_len_i` from 32 bits to 16 or 12 bits to save flip-flops and associated adder/comparator logic.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** Minor reduction.
- **Area:** ~32–40 FFs saved.

#### Required Changes
- N/A (Denied)

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Limits maximum XOF output length.

#### Notes & Decisions
- **2026-07-07**: Denied. Prefer to maintain full 32-bit XOF length support for flexibility.

---

### OPT-7: Merge the Constant Addition into the Round Counter

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [x] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-10*

#### Description
Replace the 12-entry × 8-bit round constant LUT in `constant_addition_layer` with direct logic. The round constants follow the pattern `rc[i] = {~i[3:0], i[3:0]}`, so the LUT can be replaced with `{~rnd_cnt, rnd_cnt}` — a few inverters instead of a 12-entry memory.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** Minor reduction — eliminates LUT decoder switching.
- **Area:** Small reduction — removes 12×8 LUT, replaces with 4 inverters.

#### Required Changes
- [x] `constant_addition_layer`: Replace `AsconRcLut` array with `{~rnd_i, rnd_i}` computation
- [x] Verify against `constant_addition_layer_tb`

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Minimal risk. The mathematical equivalence is easily verified.

#### Notes & Decisions
- **2026-07-07**: Pending. Acknowledged as a valid optimization, to be scheduled.
- **2026-07-10**: Completed implementation. Initial combinatorial replacement (`{~rnd_i, rnd_i}`) caused an unexpected area bloat in FPGA synthesis (LUTs increased by ~200) because it disrupted Yosys's optimization boundaries, allowing the constant addition logic to be flattened into the downstream S-box sub-optimally.
- **2026-07-10 (Resolution)**: Applied the `(* keep *)` synthesis attribute to the combinatorial round constant wire. This preserved the logic boundary while retaining the clean code, resulting in better ASIC area (`14,578.0 GEs`, beating the baseline `14,610.5 GEs`), though Yosys FPGA mapping remained slightly higher than the hardcoded LUT baseline. All testbenches passed successfully.

---

### OPT-8: Share Key Registers Between AEAD Phases

#### Status
- [x] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-07*

#### Description
In `aead_fsm`, the 128-bit key is stored in `key_r[0:1]` (128 FFs) and the received tag is stored in `rx_tag_r[0:1]` (128 FFs). Since the key and received tag are never needed simultaneously, they can share the same 128-bit register file, saving 128 FFs.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** Minor reduction — 128 fewer FFs toggling.
- **Area:** Saves 128 flip-flops.

#### Required Changes
- [ ] `aead_fsm`: Merge `key_r` and `rx_tag_r` into a shared 2×64-bit register; update read/write logic
- [ ] `aead_fsm_tb`: Verify both encryption and decryption flows still pass
- [ ] `lascon_top_tb`: Full integration regression

#### Difficulty
- **Execution Difficulty:** Medium
- **Justification/Risks:** Must carefully verify that no phase requires both key and tag simultaneously. The tag comparison in `ST_VERIFY` reads `rx_tag_r` while `key_r` is no longer needed (finalization XOR is already complete), so sharing is safe.

#### Notes & Decisions
- **2026-07-07**: Under consideration. Needs careful review of timing between key usage and tag reception.

---

### OPT-9: Remove `xor64` Module and Inline XOR

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [x] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-11*

#### Description
The `xor64` module is a trivial `assign res_o = op1_i ^ op2_i`. Inline the XOR directly into the `core_data_i` mux logic in `lascon_top`, removing one level of muxing (`xor_in_op2_sel`) and the associated control signals.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** Marginal — one fewer mux level in the datapath.
- **Area:** Small reduction — removes the `xor_sel_t` mux and simplifies control routing.

#### Required Changes
- [x] `lascon_top`: Inline XOR into `core_data_i` selection mux; remove `xor64` instantiation and `xor_in_op2_sel` mux
- [x] `xor64.sv`: Delete file
- [x] `rtl.f`: Remove `xor64.sv` entry

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Functionally identical. Simplifies the top-level datapath.

#### Notes & Decisions
- **2026-07-07**: Under consideration.
- **2026-07-11**: Completed implementation. Removed `xor64` module, removed `xor_sel_t`, updated FSMs to drive `in_data_sel` for XOR directly, and inlined XOR operations in `lascon_top` datapath muxing. Verified via automated testbenches.

---

### OPT-10: Parameterize for Single-Mode Builds

> [!WARNING]
> **Denied (2026-07-07):** Design must support all modes (AEAD + Hash/XOF) in a single build.

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [x] **Denied**

*Last Updated: 2026-07-07*

#### Description
Add top-level parameters (`ENABLE_AEAD`, `ENABLE_HASH`) to conditionally generate only the needed FSM(s), allowing deployment-specific area savings.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** Significant — eliminates unused FSM entirely.
- **Area:** High — removes entire FSM + associated mux logic for unused mode.

#### Required Changes
- N/A (Denied)

#### Difficulty
- **Execution Difficulty:** Medium
- **Justification/Risks:** Creates build variants requiring separate verification passes.

#### Notes & Decisions
- **2026-07-07**: Denied. The design is required to support both AEAD and Hash/XOF modes in a unified build.

---

### OPT-11: Simplify the `apply_padding` Function in Padder

#### Status
- [x] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-07*

#### Description
Replace the 9-branch `case` statement in `lascon_padder`'s `apply_padding` function with mask-based logic: apply a byte mask derived from TKEEP to the byte-swapped data, then OR in the `0x80` padding bit at the correct position. This replaces mux branches with AND-OR operations and a priority encoder.

#### PPA (Performance, Power, Area) Impact
- **Performance:** Negligible.
- **Power:** Minor reduction — fewer mux select lines toggling.
- **Area:** Small-to-moderate reduction — replaces wide mux tree with simpler AND-OR logic.

#### Required Changes
- [ ] `lascon_padder`: Replace `apply_padding` case statement with mask-based computation
- [ ] Verify against `lascon_padder_tb`

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Low risk. Functionally equivalent. Existing testbench should catch any regressions.

#### Notes & Decisions
- **2026-07-07**: Under consideration.

---

### OPT-12: Reduce AEAD FSM State Encoding Width

#### Status
- [x] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-07*

#### Description
Remove explicit sequential state value assignments (e.g., `= 4'd0, 4'd1...`) from the AEAD FSM `state_t` and `perm_ctx_t` enums. Let the synthesis tool choose the optimal encoding. Add `(* syn_encoding = "compact" *)` synthesis attributes to guide tools toward minimal-area encoding.

#### PPA (Performance, Power, Area) Impact
- **Performance:** Tool-dependent — may slightly affect timing.
- **Power:** Minor — fewer state bits means fewer FFs toggling.
- **Area:** Small reduction — potential saving of 1–2 FFs depending on chosen encoding.

#### Required Changes
- [ ] `aead_fsm`: Remove explicit enum value assignments; add synthesis encoding attributes
- [ ] Optional: Apply same treatment to `hash_fsm` state enum

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Transparent to simulation. Purely a synthesis-time optimization. May affect waveform debugging (state values become tool-assigned).

#### Notes & Decisions
- **2026-07-07**: Under consideration.

---

### OPT-13: Serialize Linear Diffusion (Datapath)

#### Status
- [x] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-08*

#### Description
Instead of computing all five 64-bit word rotations concurrently in `linear_diffusion_layer.sv`, instantiate a single 64-bit diffusion block and process the state sequentially over 5 clock cycles.

#### PPA (Performance, Power, Area) Impact
- **Performance:** **High latency impact**: Each permutation round will take 5+ cycles instead of 1, severely reducing throughput.
- **Power:** May reduce instantaneous power due to less parallel combinational logic.
- **Area:** High reduction in area by sharing the diffusion block across 5 cycles.

#### Required Changes
- [ ] `linear_diffusion_layer`: Update to single 64-bit block and add a 5-cycle state machine / counter.
- [ ] `lascon_core`: Adjust FSM to handle the multi-cycle diffusion step.

#### Difficulty
- **Execution Difficulty:** Medium
- **Justification/Risks:** Will severely impact throughput. Requires core control changes to manage multi-cycle diffusion.

#### Notes & Decisions
- **2026-07-08**: Identified as an area optimization strategy. Marked as pending.

---

### OPT-14: Prevent RAM Inference on State (Toolchain)

#### Status
- [x] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-08*

#### Description
Yosys often infers bulky `$DFFRAM` or block RAMs for 2D arrays like `ascon_state_t state_array` accessed via variable index (`word_sel_i`). Flatten the array to a 320-bit vector or apply `(* ram_style = "logic" *)` to force standard cell flip-flops.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** May improve power by using standard FFs instead of RAM macros.
- **Area:** Medium reduction by avoiding bulky RAM inference in Yosys.

#### Required Changes
- [ ] `lascon_core`: Apply synthesis directives to `state_array` or flatten it into a 320-bit vector.

#### Difficulty
- **Execution Difficulty:** Low
- **Justification/Risks:** Synthesis directive change with no logical functional change.

#### Notes & Decisions
- **2026-07-08**: Identified as an area optimization strategy. Marked as pending.

---

### OPT-15: Move IV Generation to Core (Control)

#### Status
- [x] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-08*

#### Description
Currently, `hash_fsm.sv` routes full 64-bit IV constants (`ASCON_HASH_IV_WORD0`, etc.) through the top-level muxing to the Core. Hardcoding these constants inside `lascon_core.sv` and triggering them via a 2-bit init signal will save significant routing area and top-level muxes.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** Minor improvement due to less toggling on wide buses.
- **Area:** Medium reduction in routing area and multiplexers at the top level.

#### Required Changes
- [ ] `lascon_core`: Move IV constants inside this module and add control signals to select them during initialization.
- [ ] `hash_fsm`: Update to output the new control signals instead of 64-bit IV constants.
- [ ] `lascon_top`: Update connections between FSM and Core.

#### Difficulty
- **Execution Difficulty:** Low
- **Justification/Risks:** Simplifies top-level routing without affecting core algorithm throughput.

#### Notes & Decisions
- **2026-07-08**: Identified as an area optimization strategy. Recommended as one of the top 2 best ROI. Marked as pending.

---

### OPT-16: Optimize Padder Carry Register Width

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [x] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-11*

#### Description
In `lascon_padder.sv`, the `pad_word2_data_reg` is a full 64-bit register used to emit the final padding word during `STATE_PAD_WORD2`. However, it only ever holds one of two constants: `64'h8000_0000_0000_0000` or `64'h0000_0000_0000_0000`. By replacing this 64-bit register with a 1-bit flag (e.g., `pad_word2_is_80_reg`), we can dynamically generate the 64-bit output combinatorially.

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** Minor reduction (fewer flip-flops switching).
- **Area:** Saves 63 flip-flops in `lascon_padder`.

#### Required Changes
- [x] `lascon_padder`: Replace `pad_word2_data_reg` and `pad_word2_data_next` with a 1-bit signal. Update `padded_tdata_o` logic in `STATE_PAD_WORD2` to use a ternary operator.

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Trivial functional equivalent change. Low risk. `lascon_padder_tb` should fully verify the change.

#### Notes & Decisions
- **2026-07-08**: Proposed as an easy area reduction. Marked as pending.

---

### OPT-17: Merge Mutually Exclusive AEAD Counters

#### Status
- [ ] **Pending**
- [ ] **In-Progress**
- [x] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-12*

#### Description
In `aead_fsm.sv`, there are multiple discrete counters used for entirely different, mutually exclusive phases of the protocol: `init_cnt_r` (3-bit), `tag_init_cnt_r` (2-bit), `tag_cnt_r` (1-bit), `verify_cnt_r` (2-bit), and `post_perm_cnt_r` (2-bit). Since these phases never overlap, these counters can be merged into a single shared 3-bit counter register (e.g., `shared_cnt_r`).

#### PPA (Performance, Power, Area) Impact
- **Performance:** None.
- **Power:** Marginal reduction.
- **Area:** Saves ~7 flip-flops and potentially simplifies control logic slightly.

#### Required Changes
- [x] `aead_fsm`: Replace discrete counters with a single `shared_cnt_r`. Update state transition logic and action logic to reset and increment this shared counter in the respective states.

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Requires careful attention to state boundary transitions to ensure the shared counter is correctly reset before entering a new phase. Verified by `aead_fsm_tb` and `lascon_top_tb`.

#### Notes & Decisions
- **2026-07-08**: Proposed as an easy area reduction. Marked as pending.
- **2026-07-12**: Implemented. Post-synthesis analysis shows a classic Logic vs. Register tradeoff:
  - **ASIC (CMOS2)**: Area decreased by 135 GEs. Trading 8 flip-flops for combinatorial multiplexing logic resulted in an overall area shrink, since FFs are physically large in standard cell design.
  - **FPGA (Xilinx 7-Series)**: LUT usage increased by 177 LUTs. FPGAs bundle LUTs and FFs in slices; saving FFs doesn't save area if the added routing/multiplexer logic consumes more LUTs. The design is smaller for ASIC, but slightly larger for FPGA.

---

### OPT-18: Replace Hash Squeeze Comparator with Down-Counter

#### Status
- [x] **Pending**
- [ ] **In-Progress**
- [ ] **Completed**
- [ ] **Denied**

*Last Updated: 2026-07-08*

#### Description
In `hash_fsm.sv`, the squeeze termination condition compares a 32-bit up-counter (`word_cnt + 1`) against a dynamically calculated 32-bit target (`target_squeeze_words`). This requires a full 32-bit adder and a 32-bit equality comparator on the combinational path for `m_axis_tlast_o`. By changing this to a down-counter loaded with `target_squeeze_words` during initialization and counting down to 1, we can replace the bulky 32-bit comparator with a simple zero/one-detector.

#### PPA (Performance, Power, Area) Impact
- **Performance:** Slightly improves critical path timing for `m_axis_tlast_o`.
- **Power:** Minor reduction.
- **Area:** Saves one 32-bit equality comparator.

#### Required Changes
- [ ] `hash_fsm`: Implement a `words_remaining_r` register. Load it with `target_squeeze_words` during initialization, decrement it during squeeze, and check `words_remaining_r == 32'd1` for `m_axis_tlast_o`.

#### Difficulty
- **Execution Difficulty:** Easy
- **Justification/Risks:** Basic RTL refactor. `hash_fsm_tb` will verify correct squeeze lengths.

#### Notes & Decisions
- **2026-07-08**: Proposed as an easy area reduction. Marked as pending.
