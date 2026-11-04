"""Bind a prepared identity and its exact CRA sources into a new shell copy."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import shell_identity_codegen as identity


def bind(top, manifest):
    hashes = manifest['abi']['source_sha256']
    values = {
        'SOURCE_ID': bytes.fromhex(manifest['source_sha256'])[::-1].hex(),
        'BUILD_ID': bytes.fromhex(manifest['build_sha256'])[::-1].hex(),
    }
    for label, suffix in [('COPY_SHA', '_Copy'), ('TRIAD_SHA', '_Triad')]:
        kernels = [k for k in manifest['abi']['kernels'] if k['name'].endswith(suffix)]
        if len(kernels) != 1:
            raise ValueError('ambiguous kernel identity')
        name = kernels[0]['name']
        values[label] = hashes[f'kernel_hdl/{name}/{name}_function_cra_agent.sv']
    for name, value in values.items():
        # These defaults belong to the new shell; never patch an already-bound copy.
        top, count = re.subn(r'\bPLATFORM_' + name + r'=0\b',
                            'PLATFORM_' + name + "=256'h" + value, top)
        if count != 1:
            raise ValueError('missing/duplicate/unexpected parameter: ' + name)
    return top, values


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--prepared', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    manifest = identity.load_prepared(a.prepared)
    original = a.source.read_bytes()
    output, values = bind(original.decode(), manifest)
    a.out.mkdir(exist_ok=False)
    (a.out / a.source.name).write_text(output)
    (a.out / 'binding.json').write_text(json.dumps({
        'source_sha256': hashlib.sha256(original).hexdigest(),
        'output_sha256': hashlib.sha256(output.encode()).hexdigest(),
        'parameters': values,
        'prepared': str(a.prepared.resolve()),
        'physical_acceptance': False}, indent=2) + '\n')

if __name__ == '__main__':
    main()
