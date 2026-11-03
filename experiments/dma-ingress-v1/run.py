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


def accepted(code, log, original):
    if code < 0 or re.search(r'Error[!:]|Error-\[|UVM_FATAL', log, re.I):
        return False
    if original:
        return (len(re.findall(r'^Fatal:', log, re.M)) == 1 and
                re.search(r'^INGRESS_EXTRA_ENQUEUE admitted=\d+ enqueued=\d+$', log, re.M)
                is not None and 'INGRESS_NATIVE_PASS' not in log)
    return (code == 0 and 'Fatal:' not in log and re.search(
        r'^INGRESS_NATIVE_PASS admitted=192 enqueued=192 popped=192 commands=192 '
        r'stalled=[1-9]\d* epochs=4$', log, re.M) is not None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('application', 'producer', 'fifo', 'model', 'lpm', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--compiler', required=True)
    parser.add_argument('--runner', required=True)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    inputs = {}
    contents = {}
    for name in ('application', 'producer', 'fifo', 'model', 'lpm'):
        path = getattr(args, name).resolve()
        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if not raw or (name in PINS and digest != PINS[name]):
            raise ValueError(name + ': source identity mismatch or empty input')
        inputs[str(path)] = digest
        contents[name] = raw
    corrected = transform(contents['application'])
    tb = Path(__file__).with_name('ingress_tb.sv')
    contents['testbench'] = tb.read_bytes()
    for path in (tb, Path(__file__), Path(__file__).with_name('build.py')):
        inputs[str(path.resolve())] = hashlib.sha256(path.read_bytes()).hexdigest()
    compiler, runner = shlex.split(args.compiler), shlex.split(args.runner)
    if not compiler or not runner:
        raise ValueError('compiler and runner must be nonempty command vectors')
    out = args.output.resolve()
    out.mkdir(exist_ok=False, parents=True)
    files = {'producer': 'producer.sv', 'fifo': 'fifo.sv', 'model': 'altera_mf.v',
             'lpm': '220model.v', 'testbench': 'ingress_tb.sv'}
    for name, filename in files.items():
        (out / filename).write_bytes(contents[name])
    result = {'prepared_only': args.prepare_only, 'inputs': inputs,
              'scope': 'native producer/FIFO; synthetic retained offer',
              'full_parent_acceptance': False, 'physical_acceptance': False, 'runs': []}

    def save():
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')

    for name, raw in [('original', contents['application']), ('corrected', corrected)]:
        work = out / name
        work.mkdir()
        (work / 'ingress_valid.svh').write_bytes(b'wire native_valid = ' + expression(raw) + b';\n')
        binary = work / 'simv'
        compile_cmd = compiler + ['-full64', '-sverilog', '-timescale=1ns/1ps',
            '+incdir+' + str(work), '-top', 'ingress_tb', '-o', str(binary)]
        compile_cmd += [str(out / f) for f in files.values()]
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
                entry['passed'] = accepted(code, log.read_text(), name == 'original')
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
