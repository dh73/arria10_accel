#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
command -v lean >/dev/null
version=$(lean --version)
printf '%s\n' "$version"
if [[ ! "$version" =~ ^Lean\ \(version\ 4\.19\.0, ]]; then
  echo "This proof gate requires Lean 4.19.0; no automatic toolchain change." >&2
  exit 2
fi
cd -- "$root"
lean tests/lean/CraCompletionConservation.lean
echo "PASS Lean 4.19.0 CRA recurrence BASE/STEP; no HDL or whole-kernel equivalence claim"
