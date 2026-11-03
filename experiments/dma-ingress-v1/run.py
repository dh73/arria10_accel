#!/usr/bin/env python3
"""Prepare or execute the native descriptor ingress comparison in a new directory."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
from build import transform

PINS = {
    'controller': '019de60946a09d16053a8cf15148a5fcbea700b1f4c9c44fd12e0485cbdabd65',
    'controller_tx': 'dd0291be6e02508db0243112552451de33bc4d82a08487c60f8bd10a0a851fa1',
    'producer': '5a6eb7dc706e78098481b7c5e11b77460c580831ba6ab2f8b9cca13626adbadd',
    'fifo': '8270ffb30fa3b75eaefd6d3d403335f04dbb0f13c894d35e9f6a6668f29f4bf8',
}


def expression(raw):
    start = raw.index(b'   write_data_mover_2               (')
    body = raw[start:raw.index(b');', start)]
    prefix = b'.WrDmaRxValid_i('
    if body.count(prefix) != 1:
        raise ValueError('native valid port is not unique')
    return body.split(prefix)[1].split(b')')[0]


def accepted(code, log, original, controller=False):
    if code < 0 or re.search(r'Error[!:]|Error-\[|UVM_FATAL', log, re.I):
        return False
    failure = (r'CONTROLLER_NATIVE_EXTRA_ENQUEUE valid=1 ready=0' if controller else
               r'INGRESS_EXTRA_ENQUEUE admitted=\d+ enqueued=\d+')
    success = (r'CONTROLLER_NATIVE_PASS descriptors=48 enqueued=48 popped=48 '
               r'commands=48 stalled=[1-9]\d*' if controller else
               r'INGRESS_NATIVE_PASS admitted=192 enqueued=192 popped=192 commands=192 '
               r'stalled=[1-9]\d* epochs=4')
    if original:
        # Bind the expected diagnostic to the unique native fatal, not arbitrary text.
        lines = log.splitlines()
        indices = [i for i, line in enumerate(lines) if line.startswith('Fatal:')]
        return (len(indices) == 1 and
                any(re.fullmatch(failure, line) for line in lines[indices[0]:indices[0]+2])
                and not re.search(r'^(?:INGRESS|CONTROLLER)_NATIVE_PASS', log, re.M))
    return code == 0 and 'Fatal:' not in log and re.search('^' + success + '$', log, re.M) is not None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('application', 'producer', 'fifo', 'model', 'lpm', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--controller', type=Path)
    parser.add_argument('--controller-tx', type=Path)
    parser.add_argument('--compiler', required=True)
    parser.add_argument('--runner', required=True)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    if bool(args.controller) != bool(args.controller_tx):
        parser.error('--controller and --controller-tx must be supplied together')
    top = 'controller_ingress_tb' if args.controller else 'ingress_tb'
    inputs = {}
    contents = {}
    names = ['application', 'producer', 'fifo', 'model', 'lpm']
    if args.controller:
        names += ['controller', 'controller_tx']
    for name in names:
        path = getattr(args, name).resolve()
        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if not raw or (name in PINS and digest != PINS[name]):
            raise ValueError(name + ': source identity mismatch or empty input')
        inputs[str(path)] = digest
        contents[name] = raw
    corrected = transform(contents['application'])
    tb = Path(__file__).with_name(top + '.sv')
    contents['testbench'] = tb.read_bytes()
    for path in (tb, Path(__file__), Path(__file__).with_name('build.py')):
        inputs[str(path.resolve())] = hashlib.sha256(path.read_bytes()).hexdigest()
    compiler, runner = shlex.split(args.compiler), shlex.split(args.runner)
    if not compiler or not runner:
        raise ValueError('compiler and runner must be nonempty command vectors')
    out = args.output.resolve()
    out.mkdir(exist_ok=False, parents=True)
    files = {'producer': 'producer.sv', 'fifo': 'fifo.sv', 'model': 'altera_mf.v',
             'lpm': '220model.v', 'testbench': top + '.sv'}
    if args.controller:
        files.update(controller='controller.sv', controller_tx='controller_tx_v4.svh')
    for name, filename in files.items():
        (out / filename).write_bytes(contents[name])
    result = {'prepared_only': args.prepare_only, 'inputs': inputs,
              'scope': ('actual write controller and native producer/FIFO' if args.controller
                        else 'native producer/FIFO; synthetic retained offer'),
              'full_parent_acceptance': False, 'physical_acceptance': False, 'runs': []}

    def save():
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')

    for name, raw in [('original', contents['application']), ('corrected', corrected)]:
        work = out / name
        work.mkdir()
        (work / 'ingress_valid.svh').write_bytes(b'wire native_valid = ' + expression(raw) + b';\n')
        binary = work / 'simv'
        compile_cmd = compiler + ['-full64', '-sverilog', '-timescale=1ns/1ps',
            '+incdir+' + str(work), '+incdir+' + str(out), '-top', top, '-o', str(binary)]
        compile_cmd += [str(out / f) for f in files.values() if not f.endswith('.svh')]
        run_cmd = runner + [str(binary), '-no_save']
        entry = {'case': name, 'compile': compile_cmd, 'simulate': run_cmd}
        result['runs'].append(entry)
        save()
        if args.prepare_only:
            continue
        for stage, cmd in [('compile', compile_cmd), ('simulate', run_cmd)]:
            log = work / (stage + '.log')
            with log.open('x') as stream:
                code = subprocess.run(cmd, cwd=work, stdout=stream,
                                      stderr=subprocess.STDOUT, check=False).returncode
            entry[stage + '_exit'] = code
            if stage == 'compile' and code != 0:
                save()
                return 1
            if stage == 'simulate':
                entry['passed'] = accepted(code, log.read_text(), name == 'original', bool(args.controller))
                if not entry['passed']:
                    save()
                    return 1
            save()
    result['sources_unchanged'] = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h
                                      for p, h in inputs.items())
    save()
    return 0 if result['sources_unchanged'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
