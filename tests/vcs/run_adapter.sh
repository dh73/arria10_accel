#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
for depths in '1 1' '3 5' '4 8'; do
  read -r commands reads <<< "$depths"
  build="$root/build/vcs-adapter-c${commands}-r${reads}"
  mkdir -p "$build"
  vcs -full64 -sverilog -timescale=1ns/1ps +define+KERNEL_DDR_ASSERTIONS \
    -top kernel_ddr_adapter_tb \
    -pvalue+kernel_ddr_adapter_tb.CMD_DEPTH="$commands" \
    -pvalue+kernel_ddr_adapter_tb.READ_DEPTH="$reads" \
    rtl/kernel_ddr_adapter.sv tests/vcs/kernel_ddr_adapter_tb.sv \
    tests/vcs/kernel_ddr_adapter_test.cpp \
    -CFLAGS "-std=c++14 -I$root/tests/vcs -DTEST_CMD_DEPTH=$commands -DTEST_READ_DEPTH=$reads" \
    -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
  vcs-run "$build/simv" > "$build/simulation.log" 2>&1
  grep '^PASS CMD_DEPTH=' "$build/simulation.log"
done
