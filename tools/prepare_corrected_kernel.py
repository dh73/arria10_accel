"""Prepare an isolated VCS file list and matching host ABI inputs.

Only the two source-pinned CRA bodies are replaced. This is not a BSP or an
image/transport qualification. Existing outputs and compiler inputs are retained.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from cra_read_clear_safe import generate
from kernel_abi import extract
from check_cra_sources import check as check_cra_sources


def prepare(root, output):
    root, output = Path(root).resolve(), Path(output).resolve()
    original = root / 'qualification/kernel-system-vcs-v1/source'
    if output.exists() or output == original or original in output.parents or output in original.parents:
        raise ValueError('fresh output outside compiler source tree required')
    original_abi = extract(original)
    lines = (root / 'qualification/kernel-system-vcs-v1/sources-23.1std.f').read_text().splitlines()
    manifest = generate(root / 'reviews/cra-completion-race-v1/source-packet.txt',
                        original, output / 'candidate')
    replacements = {item['source_relative']: item for item in manifest['files']}
    for relative, item in replacements.items():
        before, after = original / relative, output / 'candidate' / relative
        if lines.count(str(before)) != 1:
            raise ValueError('expected exactly one original CRA in file list')
        if hashlib.sha256(after.read_bytes()).hexdigest() != item['candidate_sha256']:
            raise ValueError('candidate changed')
        lines[lines.index(str(before))] = str(after)
    # A host ABI subset, not a separate complete RTL snapshot.
    for relative, digest in original_abi['source_sha256'].items():
        if hashlib.sha256((original / relative).read_bytes()).hexdigest() != digest:
            raise ValueError('original ABI input changed')
        source = (output / 'candidate' if relative in replacements else original) / relative
        target = output / 'abi-source' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    abi = extract(output / 'abi-source')
    if not all(k.get('completion_accounting') == 'delayed_snapshot_v1' for k in abi['kernels']):
        raise ValueError('corrected source profile missing')
    inputs = [Path(line) for line in lines if line.startswith('/')]
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    (output / 'source-hashes.json').write_text(json.dumps(hashes, indent=2) + '\n')
    (output / 'abi.json').write_text(json.dumps(abi, indent=2) + '\n')
    check_cra_sources(p for p in inputs if p.name.endswith("_function_cra_agent.sv"))
    # Publish the compile entry only after all checks and ABI preparation pass.
    (output / 'sources.f').write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    prepare(Path(__file__).resolve().parents[1], args.output)
