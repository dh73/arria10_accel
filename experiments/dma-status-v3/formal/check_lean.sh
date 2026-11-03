#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
set -eu
formal_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
lean_command=${LEAN_BIN:-lean}
version=$("$lean_command" --version)
case "$version" in
  'Lean (version 4.19.0,'*) ;;
  *) printf '%s\n' "Expected Lean 4.19.0, got: $version" >&2; exit 2 ;;
esac
printf '%s\n' "$version"
"$lean_command" "$formal_dir/ReuseV3.lean"
