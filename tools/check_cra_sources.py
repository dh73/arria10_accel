"""Reject stale completion-counter sources before compiling a kernel image.

Pass the actual selected CRA source files, after resolving compile overlays.
Checks source identity only; does not certify the resulting hardware image.
"""
import argparse
import hashlib
from pathlib import Path
import re
from kernel_abi import SNAPSHOT_RETIREMENT_SHA256


def check(paths):
    selected = {}
    for path in map(Path, paths):
        raw = path.read_bytes()
        names = re.findall(rb'^module\s+(\w+)_function_cra_agent\s*\(', raw, re.M)
        if len(names) != 1:
            raise ValueError(f'{path}: expected one CRA agent module')
        name = names[0].decode('ascii')
        if name in selected:
            raise ValueError(f'{path}: duplicate CRA agent {name}')
        expected = SNAPSHOT_RETIREMENT_SHA256.get(name)
        actual = hashlib.sha256(raw).hexdigest()
        if expected is None or actual != expected:
            raise ValueError(f'{path}: unqualified completion accounting for {name}')
        selected[name] = actual
    if not selected:
        raise ValueError('no selected CRA sources')
    return selected


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sources', nargs='+', type=Path)
    args = parser.parse_args()
    try:
        selected = check(args.sources)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
    for name, digest in selected.items():
        print(name, digest)
