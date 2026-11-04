#!/usr/bin/env python3
"""Prepare an unbound physical shell using the selected source transformations."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def prepare(source: Path, example: Path, out: Path) -> dict:
    source, example, out = source.resolve(), example.resolve(), out.resolve()
    if out.exists():
        raise FileExistsError(out)
    if not (source / 'platform.qsf').is_file():
        raise ValueError('Missing input platform.qsf')
    out.mkdir(parents=True)
    commands = []
    scripts = {}

    def stage(name, *args):
        script = ROOT / 'experiments' / name / 'prepare.py'
        scripts[str(script.relative_to(ROOT))] = hashlib.sha256(script.read_bytes()).hexdigest()
        command = [sys.executable, str(script), *map(str, args)]
        commands.append(command)
        subprocess.run(command, check=True)

    stage('physical-read-credits-v1', '--source', source, '--out', out/'01-credits')
    stage('physical-startup-binding-v1', '--source', out/'01-credits',
          '--hold-source', ROOT/'experiments/physical-reset-quarantine-v1/configuration_startup_hold.sv',
          '--out', out/'02-startup')
    stage('physical-support-sources-v1', '--example', example, '--out', out/'03-support')
    merged = out/'04-supported'
    merged.mkdir()
    top_name = 'platform_c126_hardware_io.sv'
    (merged/top_name).write_bytes((out/'02-startup'/top_name).read_bytes())
    qsf = (out/'02-startup/platform.qsf').read_text()
    old_top = str(out/'02-startup'/top_name)
    if qsf.count(old_top) != 1:
        raise ValueError('Ambiguous startup top assignment')
    qsf = qsf.replace(old_top, str(merged/top_name))
    qsf += '\nset_global_assignment -name QIP_FILE {'+str(out/'03-support/support.qip')+'}\n'
    (merged/'platform.qsf').write_text(qsf)
    stage('physical-status-internal-v1', '--source', merged, '--out', out/'05-status')
    stage('physical-control-binding-v1', '--source', out/'05-status', '--out', out/'candidate')
    result = {
        'state': 'prepared_unbound', 'candidate': str(out/'candidate'),
        'input_source': str(source), 'support_example': str(example),
        'commands': commands, 'transformation_sha256': scripts,
        'identity_rebinding_required': True,
        'remaining_external_inputs': ['common_cold_reset_n', 'platform_reset_containment_valid'],
        'physical_acceptance': False,
    }
    (out/'preparation.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--support-example', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.source, args.support_example, args.out)
    print(result['candidate'])


if __name__ == '__main__':
    main()
