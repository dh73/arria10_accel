#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build=${1:-"$root/build/vcs-lane-map"}
mkdir -p "$build"
cd "$root"
vcs -full64 -sverilog -timescale=1ns/1ps -top kernel_ddr_lane_map_tb \
  rtl/kernel_ddr_lane_map.sv tests/vcs/kernel_ddr_lane_map_tb.sv \
  -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
vcs-run "$build/simv" > "$build/simulation.log" 2>&1
grep '^PASS lane mapper' "$build/simulation.log"
