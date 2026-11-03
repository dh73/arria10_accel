#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${1:-"$root/build/lane-map"}
mkdir -p "$build_dir"
verilator --cc --exe --top-module kernel_ddr_lane_map --Mdir "$build_dir" \
  "$root/rtl/kernel_ddr_lane_map.sv" \
  "$root/tests/rtl/test_kernel_ddr_lane_map.cpp"
make -C "$build_dir" -f Vkernel_ddr_lane_map.mk
"$build_dir/Vkernel_ddr_lane_map"
