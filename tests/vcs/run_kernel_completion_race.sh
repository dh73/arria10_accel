#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build=${1:-"$root/build/vcs-kernel-completion-race"}
mkdir -p "$build"
cd "$root"
vcs -full64 -sverilog -timescale=1ns/1ps \
  +define+KERNEL_DDR_ASSERTIONS \
  -top kernel_completion_race_tb \
  -f qualification/kernel-system-vcs-v1/sources-23.1std.f \
  rtl/kernel_ddr_adapter.sv \
  tests/vcs/kernel_completion_race_tb.sv \
  -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
for count in 17; do
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
  grep "^PASS kernel completion race rounds=16 count=$count " "$case_dir/simulation.log"
done
