#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build=${1:-"$root/build/vcs-kernel-completion-safe"}
cd "$root"
# Generation requires a fresh isolated directory and exact original inputs.
python3 tools/cra_read_clear_safe.py \
  --packet "$root/reviews/cra-completion-race-v1/source-packet.txt" \
  --source-root "$root/qualification/kernel-system-vcs-v1/source" \
  --output-dir "$build/candidate" > /dev/null
python3 - "$root" "$build" <<'PY'
import hashlib, json, pathlib, sys
root, build = [pathlib.Path(p).resolve() for p in sys.argv[1:]]
manifest = json.loads((build / 'candidate/manifest.json').read_text())
original = root / 'qualification/kernel-system-vcs-v1/source'
lines = (root / 'qualification/kernel-system-vcs-v1/sources-23.1std.f').read_text().splitlines()
for item in manifest['files']:
    source = original / item['source_relative']
    candidate = build / 'candidate' / item['candidate_relative']
    assert hashlib.sha256(source.read_bytes()).hexdigest() == item['source_sha256']
    assert hashlib.sha256(candidate.read_bytes()).hexdigest() == item['candidate_sha256']
    assert lines.count(str(source)) == 1, 'replacement source must occur exactly once'
    lines[lines.index(str(source))] = str(candidate)
(build / 'sources.f').write_text('\n'.join(lines) + '\n')
inputs = [pathlib.Path(line) for line in lines if line.startswith('/')]
inputs += [root / 'rtl/kernel_ddr_adapter.sv',
           root / 'tests/vcs/kernel_completion_race_tb.sv']
(build / 'source-hashes.json').write_text(json.dumps(
    {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, indent=2) + '\n')
PY
vcs -full64 -sverilog -timescale=1ns/1ps +define+KERNEL_DDR_ASSERTIONS \
  -top kernel_completion_race_tb -f "$build/sources.f" \
  rtl/kernel_ddr_adapter.sv tests/vcs/kernel_completion_race_tb.sv \
  -Mdir="$build/csrc" -o "$build/simv" > "$build/compile.log" 2>&1
python3 tests/vcs/generate_kernel_fixture.py --count 17 --output "$build"
vcs-run "$build/simv" +COUNT=17 \
  "+INPUT=$build/kernel_execution_input.hex" \
  "+EXPECTED=$build/kernel_execution_expected.hex" > "$build/simulation.log" 2>&1
if grep -Eq 'Fatal:|Error!|Error-\[' "$build/simulation.log"; then
  cat "$build/simulation.log"
  exit 1
fi
grep '^PASS kernel completion race rounds=16 count=17 ' "$build/simulation.log"
python3 - "$build" <<'PY'
import hashlib, json, pathlib, re, sys
build = pathlib.Path(sys.argv[1])
text = (build / 'simulation.log').read_text()
rows = re.findall(r'^CONSERVATION base=(\d+) phase=(\d+) total=(\d+)$', text, re.M)
assert rows == [(str(base), str(phase), '1') for phase in range(16) for base in (0, 256)]
for name, digest in json.loads((build / 'source-hashes.json').read_text()).items():
    assert hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() == digest, name
print('PASS all 32 full-kernel completion observations and unchanged source hashes')
PY
