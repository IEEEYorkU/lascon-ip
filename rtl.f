# 1. Submodules (i.e. -f lib/keccak-fips202-sv/rtl.f)

# 2. Local Packages
rtl/lascon_pkg.sv
tb/permutations_sim_pkg.sv

# 3. Lascon Core Layers
rtl/substitution_layer.sv
rtl/linear_diffusion_layer.sv
rtl/constant_addition_layer.sv
rtl/lascon_core.sv

# 4. Lascon Padder
rtl/lascon_padder.sv

# 5. Lascon FSMs
rtl/hash_fsm.sv
rtl/aead_fsm.sv

# 6. Helper Modules

# 7. Lascon Top-Level
rtl/lascon_top_tt.sv
rtl/lascon_top.sv
