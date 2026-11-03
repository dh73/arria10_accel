#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build=${1:-"$root/build/vcs-read-dma-error-status"}
mkdir -p "$build"
cd "$root"
source_root=qualification/read-dma-retirement-v1/source
lib=/home/diego1/work/tools/synth/quartus/23.1std/quartus/eda/sim_lib
vcs -full64 -sverilog -timescale=1ns/1ps -top read_dma_error_status_tb \
  "$lib/altera_mf.v" "$lib/220model.v" \
  "$source_root/altpcie_fifo.sv" qualification/read-dma-retirement-v1/candidate/altpcieav_dma_rd.sv \
  "$source_root/altpcie_dynamic_control.sv" \
  tests/vcs/read_dma_error_status_tb.sv \
  -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
vcs-run "$build/simv" > "$build/simulation.log" 2>&1
if grep -Eq 'Fatal:|Error!|Error-\[' "$build/simulation.log"; then
  cat "$build/simulation.log"
  exit 1
fi
grep '^PASS read DMA error status' "$build/simulation.log"
