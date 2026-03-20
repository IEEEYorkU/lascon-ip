# --- Packages (Must be compiled first) ---
rtl/ascon_pkg.sv
tb/permutations_sim_pkg.sv

# --- Ascon Core Layers ---
rtl/substitution_layer.sv
rtl/linear_diffusion_layer.sv
rtl/constant_addition_layer.sv
rtl/ascon_core.sv

# --- Ascon Padder ---
rtl/ascon_padder.sv

# --- Ascon FSMs ---
rtl/hash_fsm.sv
rtl/aead_fsm.sv

# --- Helper Modules ---
rtl/xor64.sv

# --- Ascon Top-Level ---
rtl/ascon_top.sv
