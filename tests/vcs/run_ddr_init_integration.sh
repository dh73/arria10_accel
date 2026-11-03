#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build="$root/build/vcs-ddr-init-integration"
mkdir -p "$build"
cd "$root"
vcs -full64 -sverilog -timescale=1ns/1ps \
  +define+KERNEL_DDR_ASSERTIONS+ARRIA10_ASSERTIONS \
  -top kernel_ddr_init_integration_tb rtl/kernel_ddr_adapter.sv \
  third_party/arria10-ddr-init/arria10_ddr_init.sv \
  tests/vcs/kernel_ddr_init_integration_tb.sv \
  -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
vcs-run "$build/simv" > "$build/simulation.log" 2>&1
grep '^PASS adapter/initializer' "$build/simulation.log"
