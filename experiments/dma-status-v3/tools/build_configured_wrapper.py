#!/usr/bin/env python3
"""Preserve the exact generated C10 configuration around the v3 parent."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from build_control_wrapper import replace_once
from build_parent_wrapper import PORTS, ORIGINAL

SOURCE_SHA256 = '99966d9e0b29768c998d26c7e4044091ec8c399026c0863c860b2274f50765b6'


def transform(raw):
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError('C10 configured wrapper source SHA256 mismatch')
    text = raw.decode()
    text = replace_once(text, 'module pcie_ed_DUT (',
                        'module c10_configured_candidate_v3 (' + PORTS)
    text = replace_once(text, ORIGINAL + ' #(', 'c10_receipt_parent_candidate_v3 #(')
    names = re.findall(r'\b(CandidateRd\w+)\b', PORTS)
    connections = ''.join(f'\n        .{n}({n}),' for n in names)
    return replace_once(text, ') dut (', ') dut (' + connections)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = transform(args.source.read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output / 'c10_configured_candidate_v3.sv'
    out.write_text(result)
    (args.output / 'manifest.json').write_text(json.dumps({
        'source': str(args.source.resolve()), 'source_sha256': SOURCE_SHA256,
        'output_sha256': hashlib.sha256(out.read_bytes()).hexdigest(),
        'parameter_overrides_unchanged': True,
        'fetch_and_diagnostic_consumers_implemented': False,
        'physical_acceptance': False,
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
