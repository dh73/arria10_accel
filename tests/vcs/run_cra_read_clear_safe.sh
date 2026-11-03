#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 SOURCE_PACKET [NEW_BUILD_DIRECTORY]" >&2
  exit 2
fi
packet=$(realpath -- "$1")
source_root="$root/qualification/kernel-system-vcs-v1/source"
[[ -f "$packet" ]] || { echo "missing source packet" >&2; exit 2; }
build=$(python3 - "$source_root" "${2:-$root/build/vcs-cra-read-clear-safe}" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).resolve(strict=True)
requested = pathlib.Path(sys.argv[2]).absolute()
if requested.exists() or requested.is_symlink():
    raise SystemExit('build directory must not already exist')
build = requested.resolve()
if source == build or source in build.parents or build in source.parents:
    raise SystemExit('build directory must be isolated from immutable compiler sources')
print(build)
PY
)
command -v vcs >/dev/null
command -v vcs-run >/dev/null
mkdir -p -- "$(dirname -- "$build")"
mkdir -- "$build"
cd -- "$root"
candidate="$build/candidate"
python3 tools/cra_read_clear_safe.py --packet "$packet" \
  --source-root "$source_root" --output-dir "$candidate" \
  > "$build/transformation.log" 2>&1

compile() {
  local phase=$1 hdl_root=$2 top=$3 tb=$4
  mkdir -- "$build/$phase"
  vcs -full64 -sverilog -timescale=1ns/1ps -top "$top" \
    "$hdl_root/kernel_hdl/Pass1Kernel/Pass1Kernel_function_cra_agent.sv" \
    "$hdl_root/kernel_hdl/Pass2Kernel/Pass2Kernel_function_cra_agent.sv" \
    "$tb" -Mdir="$build/$phase/csrc" -o "$build/$phase/simv" \
    > "$build/$phase/compile.log" 2>&1
}

baseline_tb="$candidate/reference/cra_completion_race_tb.sv"
# The baseline is extracted verbatim from the pinned packet. Existing test
# files are not overwritten or trusted as replacements for that baseline.
compile original "$source_root" cra_completion_race_tb "$baseline_tb"
set +e
vcs-run "$build/original/simv" > "$build/original/simulation.log" 2>&1
original_rc=$?
set -e
# VCS wrapper exit conventions differ; require the exact expected observations
# and fatal diagnostic, with no unrelated fatal/error, instead of trusting rc.
python3 - "$build/original/simulation.log" "$original_rc" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
rows = re.findall(r'^OBSERVATION kernel=(\d+) done_offset=(-?\d+) total=(\d+)$', text, re.M)
expected = [(str(k), str(offset), '0' if offset == 0 else '1')
            for offset in range(-2, 3) for k in (1, 2)]
if rows != expected:
    raise SystemExit('original control did not reproduce the exact ten observations')
if text.count('completion conservation failed cases=2') != 1:
    raise SystemExit('original control lacks its exact expected failure')
if len(re.findall(r'^Fatal:', text, re.M)) != 1 or re.search(r'Error!|Error-\[', text):
    raise SystemExit('original control contains an unexpected error/fatal')
print('PASS expected original failure: two same-edge losses; wrapper_rc=' + sys.argv[2])
PY

run_positive() {
  local phase=$1 pass_pattern=$2
  vcs-run "$build/$phase/simv" > "$build/$phase/simulation.log" 2>&1
  if grep -Eq 'Fatal:|Error!|Error-\[' "$build/$phase/simulation.log"; then
    cat -- "$build/$phase/simulation.log"
    return 1
  fi
  grep -E "$pass_pattern" "$build/$phase/simulation.log"
}

compile baseline "$candidate" cra_completion_race_tb "$baseline_tb"
run_positive baseline '^PASS CRA completion conservation cases=10$'
compile expanded "$candidate" cra_read_clear_safe_tb tests/vcs/cra_read_clear_safe_tb.sv
run_positive expanded '^PASS CRA read-clear safe scenarios=18 agents=2 '
python3 - "$source_root" "$candidate" <<'PY'
import hashlib, json, pathlib, sys
source, candidate = map(pathlib.Path, sys.argv[1:])
manifest = json.loads((candidate / 'manifest.json').read_text())
for item in manifest['files']:
    for root, relative, digest in (
        (source, item['source_relative'], item['source_sha256']),
        (candidate, item['candidate_relative'], item['candidate_sha256']),
    ):
        if hashlib.sha256((root / relative).read_bytes()).hexdigest() != digest:
            raise SystemExit('source or candidate changed during regression: ' + relative)
print('PASS original and candidate source hashes unchanged')
PY
echo "PASS candidate CRA regressions; no hardware/read_clear_safe capability was enabled"
