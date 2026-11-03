#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build=${1:-"$root/build/vcs-repeated-kernel"}
mkdir -p "$build"
cd "$root"
# Retain prior runs; each new compile gets isolated corrected CRA/ABI inputs.
build=$(mktemp -d "$build/run.XXXXXX")
python3 tools/prepare_corrected_kernel.py "$build/kernel-inputs"
printf 'Corrected kernel build: %s\n' "$build"
vcs -full64 -sverilog -timescale=1ns/1ps \
  +define+KERNEL_DDR_ASSERTIONS \
  -top repeated_kernel_execution_tb \
  -f "$build/kernel-inputs/sources.f" \
  rtl/kernel_ddr_adapter.sv \
  tests/vcs/repeated_kernel_execution_tb.sv \
  -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
for count in 1 17 257; do
  case_dir="$build/$count"
  mkdir -p "$case_dir"
  python3 tests/vcs/generate_kernel_fixture.py --count "$count" --output "$case_dir"
  vcs-run "$build/simv" "+COUNT=$count" \
    "+INPUT=$case_dir/kernel_execution_input.hex" \
    "+EXPECTED=$case_dir/kernel_execution_expected.hex" > "$case_dir/simulation.log" 2>&1
  if grep -Eq 'Fatal:|Error!|Error-\[' "$case_dir/simulation.log"; then
    cat "$case_dir/simulation.log"
    exit 1
  fi
  grep "^PASS repeated kernels rounds=4 count=$count " "$case_dir/simulation.log"
done
