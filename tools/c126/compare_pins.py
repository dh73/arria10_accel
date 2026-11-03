#!/usr/bin/env python3
"""Compare explicit QSF package pins without executing Tcl or qualifying hardware."""
import argparse
import hashlib
import json
import re
from pathlib import Path

from c126_preflight import PreflightError, _logical_lines, tcl_words


def read_map(path):
    raw = path.read_bytes()
    pins, owners, devices, references = {}, {}, [], []
    for line_no, line in _logical_lines(raw.decode('utf-8')):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        words = tcl_words(line)
        if not words:
            continue
        if words[0] not in {'set_location_assignment', 'set_global_assignment',
                            'set_instance_assignment'}:
            raise ValueError(f'{path}:{line_no}: unsupported command; export explicit assignments first')
        if any('$' in w or ';' in w for w in words):
            raise ValueError(f'{path}:{line_no}: dynamic or multiple commands unsupported')
        if words[0] == 'set_location_assignment':
            if len(words) != 4 or words[2] != '-to':
                raise ValueError(f'{path}:{line_no}: unsupported location assignment')
            pin, port = words[1], words[3]
            if not re.fullmatch(r'PIN_[A-Z]+[0-9]+', pin):
                raise ValueError(f'{path}:{line_no}: not an explicit package pin')
            if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*(?:\[[0-9]+\])?', port):
                raise ValueError(f'{path}:{line_no}: unsupported port expression')
            if port in pins or pin in owners:
                raise ValueError(f'{path}:{line_no}: duplicate port or occupied pin')
            pins[port], owners[pin] = pin, port
        elif words[0] == 'set_global_assignment':
            if len(words) < 4 or words[1] != '-name':
                raise ValueError(f'{path}:{line_no}: unsupported global assignment')
            if words[2] == 'DEVICE':
                if len(words) != 4:
                    raise ValueError('Scoped device assignment unsupported')
                devices.append(words[3])
            if words[2].endswith('_FILE'):
                references.append({'kind': words[2], 'path': words[3]})
    if len(devices) != 1 or not pins:
        raise ValueError(f'{path}: require one device and nonempty explicit pin map')
    return {'path': str(path.resolve()), 'sha256': hashlib.sha256(raw).hexdigest(),
            'device': devices[0], 'pins': pins, 'unevaluated_references': references}


def compare(candidate, reference, mapping=None):
    mapping = mapping if mapping is not None else {p: p for p in candidate['pins']}
    if not isinstance(mapping, dict) or set(mapping) != set(candidate['pins']):
        raise ValueError('Mapping must cover exactly every candidate port')
    if not all(isinstance(v, str) for v in mapping.values()) or len(set(mapping.values())) != len(mapping):
        raise ValueError('Mapping must be a one-to-one string port mapping')
    missing, conflicts, matches = [], [], []
    for port, other in sorted(mapping.items()):
        actual = candidate['pins'][port]
        expected = reference['pins'].get(other)
        item = {'candidate_port': port, 'reference_port': other,
                'candidate_pin': actual, 'reference_pin': expected}
        (missing if expected is None else matches if actual == expected else conflicts).append(item)
    device_match = candidate['device'] == reference['device']
    return {'scope': 'explicit package-pin assignments only; no Tcl evaluation',
            'candidate': candidate, 'reference': reference, 'mapping': mapping,
            'device_match': device_match, 'matches': matches,
            'missing': missing, 'conflicts': conflicts,
            'explicit_map_match': not missing and not conflicts,
            'source_comparison_pass': device_match and not missing and not conflicts,
            'physical_acceptance': False, 'electrical_acceptance': False,
            'clock_reset_timing_acceptance': False,
            'reference_extra_ports': sorted(set(reference['pins']) - set(mapping.values()))}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--mapping', type=Path)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    try:
        mapping = json.loads(a.mapping.read_text()) if a.mapping else None
        result = compare(read_map(a.candidate), read_map(a.reference), mapping)
    except (ValueError, OSError, PreflightError) as exc:
        result = {'source_comparison_pass': False, 'error': str(exc),
                  'physical_acceptance': False}
    with a.output.open('x') as out:
        json.dump(result, out, indent=2)
        out.write('\n')
    return 0 if result['source_comparison_pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
