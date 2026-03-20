# =====================
# Dual-Simulator Makefile
# =====================

# 1. Dynamically read RTL files from the filelist (rtl.f)
# - grep -v '^\#' ignores commented lines
# - grep -v '^$$' ignores empty lines
# This preserves the exact order from the filelist rtl.f
RTL_FILES = $(shell grep -v '^\#' rtl.f | grep -v '^$$')

# 2. Automatically discover all testbenches
# This looks in the tb/ directory for anything ending in _tb.sv
# and strips the "tb/" and ".sv" to get the module name (e.g., substitution_layer_tb)
TESTBENCHES = $(patsubst tb/%.sv,%,$(wildcard tb/*_tb.sv))

# Simulator selection (default to vsim if not specified)
# Usage: make run_all SIM=verilator
SIM ?= vsim

# --- VERILATOR FLAGS ---
# --binary: Build an executable (requires Verilator v5.0+)
# --timing: Support delay statements (#1ns) in SV
# --trace:  Enable VCD tracing
VERILATOR_FLAGS = --binary -j 0 --timing --trace -Wall -Wno-fatal

# Python vector generation
PYTHON      ?= python3
PY_SCRIPT   := verif/test_scripts/core_test.py
AEAD_PY_SCRIPT := verif/test_scripts/aead_test.py
VECTOR_FILE := verif/test_vectors/ascon_vectors.txt
AEAD_VECTOR_FILE := verif/test_vectors/aead_vectors.txt

# Default target
all: run_all

.PHONY: run_all clean run_% FORCE

# Always regenerate vectors before simulation
$(VECTOR_FILE): FORCE
	@echo "=== Generating Python Core test vectors ==="
	$(PYTHON) $(PY_SCRIPT)

$(AEAD_VECTOR_FILE): FORCE
	@echo "=== Generating Python AEAD test vectors ==="
	$(PYTHON) $(AEAD_PY_SCRIPT)


# Loop through testbenches
run_all:
	@for tb in $(TESTBENCHES); do \
		$(MAKE) run_$$tb; \
	done

# Rule for each testbench
run_%: $(VECTOR_FILE)
	@echo "=== Running $* with $(SIM) ==="
ifeq ($(SIM), verilator)
	# --- VERILATOR FLOW ---
	# Pass the filelist natively with -f
	verilator $(VERILATOR_FLAGS) \
		+incdir+rtl \
		--top-module $* \
		-f rtl.f \
		tb/$*.sv

	./obj_dir/V$*
else
	# --- MODELSIM FLOW ---
	vlib work
	# Pass the filelist natively with -f
	vlog -work work -sv +incdir+rtl -f rtl.f tb/$*.sv

	@echo 'vcd file "$*.vcd"' > run_$*.macro
	@echo 'vcd add -r /$*/*' >> run_$*.macro
	@echo 'run -all' >> run_$*.macro
	@echo 'quit' >> run_$*.macro
	vsim -c -do run_$*.macro work.$*
	rm -f run_$*.macro
endif

# Clean build files
clean:
	rm -rf work *.vcd transcript vsim.wlf run_*.macro
	rm -rf obj_dir
