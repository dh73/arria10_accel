#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build=${1:-"$root/build/vcs-cra-completion-race"}
mkdir -p "$build"
cd "$root"
source_root=qualification/kernel-system-vcs-v1/source/kernel_hdl
vcs -full64 -sverilog -timescale=1ns/1ps -top cra_completion_race_tb \
  "$source_root/Pass1Kernel/Pass1Kernel_function_cra_agent.sv" \
  "$source_root/Pass2Kernel/Pass2Kernel_function_cra_agent.sv" \
  tests/vcs/cra_completion_race_tb.sv \
  -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
vcs-run "$build/simv" > "$build/simulation.log" 2>&1
if grep -Eq 'Fatal:|Error!|Error-\[' "$build/simulation.log"; then
  cat "$build/simulation.log"
  exit 1
fi
grep '^PASS CRA completion conservation cases=10' "$build/simulation.log"
