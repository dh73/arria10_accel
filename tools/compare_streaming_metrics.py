"""Compare completed streaming simulations with identical pinned fixtures.

Ratios describe simulated workload cycles, never board bandwidth. Callers must
name the testbench, adapter and model/library inputs that define the fixture.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

METRIC = re.compile(r'^STREAM_METRIC base=(\d+) count=(\d+) reads=(\d+) writes=(\d+) full_writes=(\d+) write_bytes=(\d+) cycles=(\d+)$', re.M)
FIELDS = ('base', 'count', 'reads', 'writes', 'full_writes', 'write_bytes', 'cycles')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def load(job):
    result = json.loads((job / 'result.json').read_text())
    commands = json.loads((job / 'commands.json').read_text())
    require(result.get('state') == 'passed' and result.get('sources_unchanged') is True,
            f'{job}: qualification not passed')
    require(result.get('suite_exits') == [0] * len(commands), 'incomplete suite')
    pins = json.loads((job / 'sources.json').read_text())
    rows = {}
    for i, (_, marker) in enumerate(commands):
        text = (job / f'suite-{i}.log').read_text()
        require(not re.search(r'Fatal:|Error!|Error:|Error-\[', text), 'native error')
        if marker is None:
            continue
        require(sum(line.startswith(marker) for line in text.splitlines()) == 1,
                'missing or repeated acceptance marker')
        metrics = METRIC.findall(text)
        require(len(metrics) == 2, 'expected copy and triad metrics per workload')
        for values in metrics:
            row = dict(zip(FIELDS, map(int, values)))
            key = row['base'], row['count']
            require(key not in rows and row['cycles'] > 0, 'duplicate or invalid metric')
            require(row['write_bytes'] == row['count'] * 4, 'output byte count mismatch')
            rows[key] = row
    require(rows, 'no measurements')
    return pins, rows, commands


def compare(baseline, candidate, fixture):
    bp, br, bc = load(baseline)
    cp, cr, cc = load(candidate)
    require(set(br) == set(cr), 'workload matrix differs')
    require(len(bc) == len(cc), 'command matrix differs')
    # Compile output/include paths vary by generated job; other options must match.
    def normalize(cmd):
        return ['<path>' if x.startswith('/') or x.startswith(('+incdir+', '-Mdir='))
                else x for x in cmd]
    require([normalize(c) for c, _ in bc] == [normalize(c) for c, _ in cc],
            'simulation flags or runtime arguments differ')
    for path in fixture:
        name = str(path.resolve())
        require(name in bp and name in cp and bp[name] == cp[name],
                f'fixture pin differs or absent: {name}')
        require(hashlib.sha256(path.read_bytes()).hexdigest() == bp[name],
                f'fixture bytes changed: {name}')
    return {'scope': 'identical-fixture simulated workload cycles',
            'physical_acceptance': False,
            'fixture_pins': {str(p.resolve()): bp[str(p.resolve())] for p in fixture},
            'comparisons': [{'base': k[0], 'count': k[1], 'baseline': br[k],
                             'candidate': cr[k],
                             'cycle_speedup': br[k]['cycles'] / cr[k]['cycles']}
                            for k in sorted(br)]}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('baseline', type=Path)
    p.add_argument('candidate', type=Path)
    p.add_argument('--fixture', type=Path, action='append', required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    result = compare(a.baseline, a.candidate, a.fixture)
    with a.output.open('x') as f:
        json.dump(result, f, indent=2)
        f.write('\n')
