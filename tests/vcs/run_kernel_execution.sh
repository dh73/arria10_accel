#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build=${1:-"$root/build/vcs-kernel-execution"}
mkdir -p "$build"
cd "$root"
# Retain prior runs; each new compile gets isolated corrected CRA/ABI inputs.
build=$(mktemp -d "$build/run.XXXXXX")
python3 tools/prepare_corrected_kernel.py "$build/kernel-inputs"
printf 'Corrected kernel build: %s\n' "$build"
# This generated SDK source includes Stratix V FIFO defaults. Retain the full
# vendor 23.1std simulation-library tuple, not a patched/custom FIFO model.
vcs -full64 -sverilog -timescale=1ns/1ps +define+KERNEL_DDR_ASSERTIONS \
  -top kernel_system_execution_tb \
  -f "$build/kernel-inputs/sources.f" \
  rtl/kernel_ddr_adapter.sv tests/vcs/kernel_system_execution_tb.sv \
  -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
python3 tests/vcs/generate_kernel_fixture.py --count 17 --output "$build"
vcs-run "$build/simv" +COUNT=17 \
  "+INPUT=$build/kernel_execution_input.hex" \
  "+EXPECTED=$build/kernel_execution_expected.hex" > "$build/simulation.log" 2>&1
# VCS/native vendor $finish paths can return zero even after a fatal diagnostic.
if grep -Eq 'Fatal:|Error!|Error-\[' "$build/simulation.log"; then
  cat "$build/simulation.log"
  exit 1
fi
grep '^PASS actual kernels' "$build/simulation.log"
