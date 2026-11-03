#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build=${1:-"$root/build/vcs-read-dma-multi-candidate"}
mkdir -p "$build"
cd "$root"
source_root=qualification/read-dma-retirement-v1/source
lib=/home/diego1/work/tools/synth/quartus/23.1std/quartus/eda/sim_lib
vcs -full64 -sverilog -timescale=1ns/1ps -top read_dma_multi_retirement_tb \
  "$lib/altera_mf.v" "$lib/220model.v" \
  "$source_root/altpcie_fifo.sv" qualification/read-dma-retirement-v1/candidate/altpcieav_dma_rd.sv \
  tests/vcs/read_dma_multi_retirement_tb.sv \
  -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
for descriptors in 2 4 8; do
for mode in 0 1 2 3 4 5; do
  vcs-run "$build/simv" "+MODE=$mode" "+DESCRIPTORS=$descriptors" > "$build/simulation-$descriptors-$mode.log" 2>&1
  if grep -Eq 'Fatal:|Error!|Error-\[' "$build/simulation-$descriptors-$mode.log"; then
    cat "$build/simulation-$descriptors-$mode.log"
    exit 1
  fi
  grep "^PASS read DMA multi mode=$mode descriptors=$descriptors " "$build/simulation-$descriptors-$mode.log"
done
done
