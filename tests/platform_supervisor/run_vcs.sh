#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${BUILD_DIR:-"$repo_root/build/platform-supervisor-vcs"}
vcs_bin=${VCS_BIN:-vcs}
vcs_run=${VCS_RUN:-vcs-run}
if ! command -v "$vcs_bin" >/dev/null 2>&1; then
  printf 'VCS executable unavailable: %s\n' "$vcs_bin" >&2
  exit 127
fi
mkdir -p -- "$build_dir"
cd -- "$build_dir"
"$vcs_bin" -full64 -sverilog -timescale=1ns/1ps \
  +define+KERNEL_DDR_ASSERTIONS +define+ARRIA10_ASSERTIONS \
  +define+PLATFORM_SUPERVISOR_ASSERTIONS \
  -top tb_platform_supervisor \
  "$repo_root/rtl/platform_supervisor.sv" \
  "$repo_root/rtl/platform_supervised_ddr_adapter.sv" \
  "$repo_root/rtl/kernel_ddr_adapter.sv" \
  "$repo_root/third_party/arria10-ddr-init/arria10_ddr_init.sv" \
  "$repo_root/tests/platform_supervisor/tb_platform_supervisor.sv" \
  -o "$build_dir/simv" -l "$build_dir/compile.log"
"$vcs_run" "$build_dir/simv" -l "$build_dir/sim.log"
if grep -Eq '(^|[[:space:]])(Error:|Error-|Fatal:|Fatal-)' \
  "$build_dir/sim.log"; then
  printf 'Simulator error/fatal diagnostic found; simulation is not a pass.\n' >&2
  exit 1
fi
if ! grep -Fxq 'PASS platform_supervisor contract and real adapter/init tests' \
  "$build_dir/sim.log"; then
  printf 'Missing test completion marker; simulation is not a pass.\n' >&2
  exit 1
fi
