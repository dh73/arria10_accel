#!/usr/bin/env python3
"""Run the independent native D2H packetizer fixture with actual private RTL.

VCS only. Source identities are checked before a fresh private build is made.
There is no simulation timeout, descriptor-length cap, RAM cap, or retry.
--prepare-only writes inputs and commands without claiming VCS execution.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TOP = 'native_d2h_packetizer_tb'
PASS = 'NATIVE_D2H_PACKETIZER_PASS'
QUARANTINE_PASS = 'NATIVE_D2H_QUARANTINE_PASS'
STATUS_FAILURE = 'D2H_STATUS_EARLY'
SUITES = {
    'status-witness': ('status', STATUS_FAILURE, True),
    'status-corrected': ('status', PASS, False),
    'full': ('matrix', PASS, False),
    'quarantine': ('quarantine', QUARANTINE_PASS, False),
}
PRODUCER_SHA = '9658fce313dc40ea278021747923137a9cad5fc3df344ecc6818e63e010aef54'
CORRECTED_PRODUCER_SHA = '5a6eb7dc706e78098481b7c5e11b77460c580831ba6ab2f8b9cca13626adbadd'
PINS = {
    'mux': 'e7d1a716558f273876ae5ec8f98f6a83f98b79e793e5ed07e42eaba3e2f7cb3b',
    'wrapper': '5faf8d9c622e7aeff2f3f77b94e3dddd9b6cac17272892a8b5493412986ee4fe',
    'aligner': '792d039c00e605df32157b7de48e749ea6c1343639832527aa170e3100b344fa',
    'tlpgen': 'c4a38772eec21339f84a1a9e183e111302d0263693e1e230ba1171bab7b7a01f',
    'fifo': '8270ffb30fa3b75eaefd6d3d403335f04dbb0f13c894d35e9f6a6668f29f4bf8',
}


class UnavailableTool(Exception):
    pass


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def read_source(value: str | Path, label: str,
                pins: tuple[str, ...] = ()) -> tuple[Path, bytes]:
    path = Path(value).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f'{label}: missing actual source {path}')
    raw = path.read_bytes()
    if not raw:
        raise ValueError(f'{label}: empty source {path}')
    if pins and sha(raw) not in pins:
        raise ValueError(f'{label}: SHA256 mismatch, got {sha(raw)}: {path}')
    return path, raw


def command(value: str, label: str, prepare: bool) -> list[str]:
    words = shlex.split(value)
    if not words:
        raise ValueError(label + ': empty command')
    words[0] = os.path.expanduser(words[0])
    found = shutil.which(words[0])
    if not found and not prepare:
        raise UnavailableTool(label + ' executable unavailable: ' + words[0])
    if found:
        # The host launcher dispatches on argv[0]. DO NOT resolve its symlink.
        words[0] = os.path.abspath(found)
    return words


def execute(argv: list[str], log: Path, work: Path) -> int:
    log.with_suffix('.command.json').write_text(json.dumps(argv, indent=2) + '\n')
    with log.open('w') as stream:
        return subprocess.run(argv, cwd=work, stdout=stream,
                              stderr=subprocess.STDOUT, check=False).returncode


def passed_run(code: int, text: str, witness: bool, marker: str = PASS) -> bool:
    passed_marker = re.search(r'^' + re.escape(marker) + r'\b', text, re.M) is not None
    if witness:
        # An arbitrary compile error, timeout, signal, or nonzero exit is NOT
        # the required negative result. Match this bench's structured native
        # diagnostic in the unique VCS Fatal block, on its header or next line.
        lines = text.splitlines()
        fatal_lines = [i for i, line in enumerate(lines)
                       if re.match(r'^\s*Fatal:', line, re.I)]
        diagnostic = (r'\b' + STATUS_FAILURE +
                      r'\s+descriptor=[0-9]+\s+enqueued=[0-9]+'
                      r'\s+required=[1-9][0-9]*\s+tx_write=[01]\b')
        native_fatal = False
        if len(fatal_lines) == 1:
            index = fatal_lines[0]
            native_fatal = any(re.search(diagnostic, line) is not None
                               for line in lines[index:index + 2])
        # This native launcher may return zero after $fatal; require the exact
        # unique fatal instead, and reject all other model/runtime errors.
        return (code >= 0 and
                re.search(r'^NATIVE_D2H_\w+_PASS\b', text, re.M) is None and
                native_fatal and
                re.search(r'Error[!:]|Error-\[|UVM_FATAL', text, re.I) is None)
    return (code == 0 and passed_marker and
            re.search(r'Fatal:|Error[!:]|Error-\[|UVM_FATAL|assertion.*fail',
                      text, re.I) is None)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--suite', choices=tuple(SUITES) + ('all',), default='full')
    for name in ('payload', 'mux', 'producer', 'fifo', 'wrapper', 'aligner', 'tlpgen'):
        p.add_argument('--' + name, required=True, help='actual PRIVATE ' + name + ' source')
    p.add_argument('--quartus-simlib', type=Path, required=True,
                   help='actual eda/sim_lib containing altera_mf.v and 220model.v')
    p.add_argument('--extra-filelist', type=Path,
                   help='additional real dependencies; use absolute paths inside this filelist')
    p.add_argument('--vcs', default=os.environ.get('VCS', 'vcs'))
    p.add_argument('--runner', default=os.environ.get('VCS_RUN', 'vcs-run'),
                   help='simulation launcher; --runner= executes compiled simv directly')
    p.add_argument('--seed', type=int, action='append', help='default: 1, 17, 73')
    p.add_argument('--vcs-arg', action='append', default=[])
    p.add_argument('--sim-arg', action='append', default=[])
    p.add_argument('--build-dir', type=Path, required=True, help='NEW PRIVATE directory')
    p.add_argument('--prepare-only', action='store_true')
    a = p.parse_args()
    seeds = a.seed or [1, 17, 73]
    if len(set(seeds)) != len(seeds) or any(not 0 < s < 2**32 for s in seeds):
        raise ValueError('seeds must be distinct nonzero uint32 values')
    if any(arg.startswith(('+CASE=', '+SEED=', '+ntb_random_seed=')) for arg in a.sim_arg):
        raise ValueError('CASE and SEED are selected by --suite and --seed')

    # Import only after argument parsing so --help needs no private inputs.
    sys.path.insert(0, str(ROOT / 'tools'))
    from build_payload_unaligned import transform as transform_payload
    from build_readmem_count import transform as transform_producer
    from build_packetizer import transform_aligner, transform_tlpgen

    inputs: dict[str, str] = {}
    originals: dict[str, bytes] = {}
    for name in ('payload', 'mux', 'producer', 'fifo', 'wrapper', 'aligner', 'tlpgen'):
        pins = ((PRODUCER_SHA, CORRECTED_PRODUCER_SHA) if name == 'producer'
                else ((PINS[name],) if name in PINS else ()))
        path, raw = read_source(getattr(a, name), '--' + name, pins)
        inputs[str(path)] = sha(raw)
        originals[name] = raw
    payload = transform_payload(originals['payload']).encode('utf-8')
    producer = originals['producer']
    if sha(producer) == PRODUCER_SHA:
        producer = transform_producer(producer)
    if sha(producer) != CORRECTED_PRODUCER_SHA:
        raise ValueError('19-bit producer derivative SHA256 mismatch')
    aligner = transform_aligner(originals['aligner'])
    tlpgen = transform_tlpgen(originals['tlpgen'])
    if not isinstance(aligner, bytes) or not isinstance(tlpgen, bytes):
        raise TypeError('packetizer transformations must return exact bytes')

    models = []
    for name in ('altera_mf.v', '220model.v'):
        path, raw = read_source(a.quartus_simlib / name, name)
        inputs[str(path)] = sha(raw)
        models.append((name, raw))
    composition, composition_raw = read_source(
        ROOT / 'rtl/dma_memory_path_unaligned_candidate.sv', 'composition')
    testbench, testbench_raw = read_source(ROOT / 'tests' / (TOP + '.sv'), 'testbench')
    inputs[str(composition)] = sha(composition_raw)
    inputs[str(testbench)] = sha(testbench_raw)
    for name in ('build_payload_unaligned.py', 'build_payload_mask.py',
                 'build_control_wrapper.py', 'build_readmem_count.py', 'build_packetizer.py'):
        path, raw = read_source(ROOT / 'tools' / name, 'transformer')
        inputs[str(path)] = sha(raw)
    inputs[str(Path(__file__).resolve())] = sha(Path(__file__).read_bytes())
    extra = []
    if a.extra_filelist:
        path, raw = read_source(a.extra_filelist, '--extra-filelist')
        inputs[str(path)] = sha(raw)
        extra = ['-f', str(path)]
    vcs = command(a.vcs, 'VCS', a.prepare_only)
    runner = command(a.runner, 'VCS runner', a.prepare_only) if a.runner else []

    # ALL input validation/transformations precede the first output directory.
    build = a.build_dir.expanduser().resolve()
    build.mkdir(parents=True, exist_ok=False, mode=0o700)
    sources = {
        'dma_payload_unaligned_candidate.sv': payload,
        'arria10_dma_ddr_mux.sv': originals['mux'],
        'altpcieav_dma_wr_readmem_2.sv': producer,
        'altpcie_fifo.sv': originals['fifo'],
        'altpcieav_dma_wr_2.sv': originals['wrapper'],
        'altpcieav_dma_wr_wdalign_2.sv': aligner,
        'dma_memory_path_unaligned_candidate.sv': composition_raw,
        TOP + '.sv': testbench_raw,
        **dict(models),
    }
    for name, raw in sources.items():
        (build / name).write_bytes(raw)
    results = {
        'prepared_only': a.prepare_only,
        'scope': 'native descriptor ingress through actual wrapper to output FIFO enqueue',
        'inputs': inputs,
        'generated': {name: sha(raw) for name, raw in sources.items()},
        'extra_filelist': str(a.extra_filelist) if a.extra_filelist else None,
        'runs': [],
    }
    # A caller-supplied extra filelist is passed intact; its own hash is recorded.
    # Its transitive dependency contents are not claimed to be pinned here.
    output = build / 'results.json'

    def record() -> None:
        temporary = output.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(results, indent=2) + '\n')
        temporary.replace(output)

    suites = tuple(SUITES) if a.suite == 'all' else (a.suite,)
    jobs = []
    for suite in suites:
        case, marker, witness = SUITES[suite]
        work = build / suite
        work.mkdir(mode=0o700)
        packetizer = work / 'altpcieav_dma_wr_tlpgen_2.sv'
        packetizer.write_bytes(originals['tlpgen'] if witness else tlpgen)
        binary = work / 'simv'
        argv = vcs + ['-full64', '-sverilog', '-timescale=1ns/1ps',
                      '+define+ARRIA10_ASSERTIONS', '-top', TOP, '-o', str(binary)]
        argv += a.vcs_arg + extra + [str(build / name) for name in sources] + [str(packetizer)]
        entry = {'suite': suite, 'top': TOP, 'compile_argv': argv,
                 'compile_attempted': False, 'tlpgen_sha256': sha(packetizer.read_bytes()),
                 'expected': marker, 'simulations': []}
        results['runs'].append(entry)
        jobs.append((case, marker, witness, work, binary, argv, entry))
    record()
    for case, marker, witness, work, binary, argv, entry in jobs:
        if not a.prepare_only:
            entry['compile_attempted'] = True
            record()
            code = execute(argv, work / 'compile.log', work)
            entry['compile_returncode'] = code
            record()
            if code or not binary.is_file():
                print(f'FAIL compile: {work / "compile.log"}', file=sys.stderr)
                return 1
        for seed in seeds:
            argv = runner + [str(binary), '-no_save', f'+ntb_random_seed={seed}',
                             f'+SEED={seed}', '+CASE=' + case] + a.sim_arg
            run = {'seed': seed, 'argv': argv, 'attempted': False}
            entry['simulations'].append(run)
            record()
            if a.prepare_only:
                continue
            run['attempted'] = True
            record()
            log = work / f'seed_{seed}.log'
            code = execute(argv, log, work)
            passed = passed_run(code, log.read_text(errors='replace'), witness, marker)
            run.update(returncode=code, passed=passed)
            if witness:
                run['expected_failure_observed'] = passed
            record()
            print(f'{"PASS" if passed else "FAIL"} {entry["suite"]} seed={seed}: {log}')
            if not passed:
                return 1
    print(('PREPARED ONLY; no VCS compile/simulation executed: ' if a.prepare_only
           else 'Requested VCS packetizer suite completed: ') + str(output))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except UnavailableTool as error:
        print(f'UNAVAILABLE: {error}; no VCS execution', file=sys.stderr)
        raise SystemExit(77)
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        print(f'INPUT/EXECUTION ERROR: {error}', file=sys.stderr)
        raise SystemExit(2)
