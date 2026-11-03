#!/usr/bin/env python3
"""Private exact-source D2H-head regression. VCS only; no retry or runtime cap.

Creates a NEW build directory. Vendor/peer/generated sources never become repo
assets. --prepare-only writes inputs/commands but does not claim compilation.
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
sys.path.insert(0, str(ROOT / 'tools'))
from build_control_wrapper import replace_once
from build_payload_unaligned import mask_source, transform

MUX_SHA = 'e7d1a716558f273876ae5ec8f98f6a83f98b79e793e5ed07e42eaba3e2f7cb3b'
PRODUCER_SHA = '9658fce313dc40ea278021747923137a9cad5fc3df344ecc6818e63e010aef54'
PINS = {
    'payload_mask_tb.sv': 'a64912c5720e94512a455c901502ecf2d36fe87900782f04b8be050dca7e91ed',
    'memory_path_tb.sv': '3a348060d6cd05f41b6808026c4721ff1b1994a2256d320ac316dc73005cd293',
    'payload_unaligned_witness_tb.sv': '6d1f19c9d242acbb22164b48a60e2404eb676ac152828a6266532a0f3c8d1688',
}


def read_source(value: str | Path | None, label: str, pin: str | None = None) -> tuple[Path, bytes]:
    if not value:
        raise ValueError(label + ' is required')
    path = Path(value).expanduser().resolve()
    if not path.is_file():
        raise ValueError(label + ' missing file: ' + str(path))
    raw = path.read_bytes()
    if pin and hashlib.sha256(raw).hexdigest() != pin:
        raise ValueError(label + ' SHA256 mismatch: ' + str(path))
    return path, raw


def command(value: str, label: str, prepare: bool) -> list[str]:
    words = shlex.split(value)
    resolved = shutil.which(words[0]) if words else None
    if not words or (not prepare and not resolved):
        raise FileNotFoundError(label + ' executable unavailable: ' + value)
    if resolved:
        # Multi-tool wrappers dispatch on argv[0]; preserve the vcs/vcs-run link.
        words[0] = os.path.abspath(resolved)
    return words


def execute(argv: list[str], log: Path, work: Path) -> int:
    log.with_suffix('.command.json').write_text(json.dumps(argv, indent=2) + '\n')
    with log.open('w') as stream:
        return subprocess.run(argv, cwd=work, stdout=stream,
                              stderr=subprocess.STDOUT, check=False).returncode


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--suite', choices=('all', 'direct', 'native', 'regression', 'witness'), default='all')
    p.add_argument('--payload', required=True, help='exact original or mask candidate, PRIVATE')
    p.add_argument('--mux', required=True, help='exact retained arria10_dma_ddr_mux.sv, PRIVATE')
    p.add_argument('--producer', help='exact altpcieav_dma_wr_readmem_2.sv, PRIVATE')
    p.add_argument('--fifo', help='actual altpcie_fifo implementation, PRIVATE; no stub')
    p.add_argument('--quartus-simlib', help='actual eda/sim_lib containing altera_mf.v and 220model.v')
    p.add_argument('--extra-filelist', help='optional actual vendor dependency filelist; absolute paths')
    p.add_argument('--vcs', default=os.environ.get('VCS', 'vcs'))
    p.add_argument('--runner', default=os.environ.get('VCS_RUN', 'vcs-run'),
                   help='execution wrapper; --runner= invokes simv directly')
    p.add_argument('--seed', type=int, action='append', help='repeatable simulation seeds; default 1,17,73')
    p.add_argument('--vcs-arg', action='append', default=[], help='additional single VCS argument')
    p.add_argument('--sim-arg', action='append', default=[], help='additional single simulation argument')
    p.add_argument('--build-dir', type=Path, required=True, help='new PRIVATE output directory')
    p.add_argument('--prepare-only', action='store_true')
    a = p.parse_args()
    suites = ('witness', 'regression', 'direct', 'native') if a.suite == 'all' else (a.suite,)
    try:
        payload_path, payload_raw = read_source(a.payload, '--payload')
        old_rtl, new_rtl = mask_source(payload_raw), transform(payload_raw)
        mux_path, mux_raw = read_source(a.mux, '--mux', MUX_SHA)
        dependencies: list[Path] = []
        inputs = {str(payload_path): hashlib.sha256(payload_raw).hexdigest(), str(mux_path): MUX_SHA}
        if 'native' in suites:
            producer, producer_raw = read_source(a.producer, '--producer', PRODUCER_SHA)
            fifo, fifo_raw = read_source(a.fifo, '--fifo')
            if not a.quartus_simlib:
                raise ValueError('--quartus-simlib required: actual lpm_add_sub and altsyncram models')
            simlib = Path(a.quartus_simlib).expanduser().resolve()
            dependencies = [producer, fifo]
            for name in ('altera_mf.v', '220model.v'):
                model, raw = read_source(simlib / name, name)
                dependencies.append(model)
                inputs[str(model)] = hashlib.sha256(raw).hexdigest()
            inputs[str(producer)] = hashlib.sha256(producer_raw).hexdigest()
            inputs[str(fifo)] = hashlib.sha256(fifo_raw).hexdigest()
        extra = []
        if a.extra_filelist:
            filelist, raw = read_source(a.extra_filelist, '--extra-filelist')
            extra = ['-f', str(filelist)]
            inputs[str(filelist)] = hashlib.sha256(raw).hexdigest()
        vcs = command(a.vcs, 'VCS', a.prepare_only)
        runner = command(a.runner, 'VCS runner', a.prepare_only) if a.runner else []
        build = a.build_dir.expanduser().resolve()
        build.mkdir(parents=True, exist_ok=False)
    except FileNotFoundError as error:
        print(f'UNAVAILABLE: {error}; no VCS compile or simulation executed', file=sys.stderr)
        return 77
    except (OSError, ValueError, UnicodeError) as error:
        print(f'INPUT ERROR: {error}', file=sys.stderr)
        return 2

    old = build / 'dma_payload_mask_candidate.sv'
    new = build / 'dma_payload_unaligned_candidate.sv'
    mux = build / 'arria10_dma_ddr_mux.sv'
    old.write_text(old_rtl)
    new.write_text(new_rtl)
    mux.write_bytes(mux_raw)
    wrapper = ROOT / 'rtl' / 'dma_memory_path_unaligned_candidate.sv'
    plans = []
    if 'witness' in suites:
        plans.append(('payload_unaligned_witness_tb', old, [], 'UNALIGNED_REJECTION_WITNESS_PASS', None))
    if 'regression' in suites:
        plans.append(('payload_mask_tb', new, [], 'PAYLOAD_MASK_PASS',
                      ('dma_payload_mask_candidate dut', 'dma_payload_unaligned_candidate dut')))
        plans.append(('memory_path_tb', new, [mux, wrapper], 'MEMORY_PATH_PASS',
                      ('dma_memory_path_candidate dut', 'dma_memory_path_unaligned_candidate dut')))
    if 'direct' in suites:
        plans.append(('unaligned_memory_path_tb', new, [mux, wrapper], 'UNALIGNED_MEMORY_PATH_PASS', None))
    if 'native' in suites:
        plans.append(('native_unaligned_head_tb', new, [mux, wrapper] + dependencies,
                      'NATIVE_UNALIGNED_HEAD_PASS', None))
    results = {'prepared_only': a.prepare_only, 'inputs': inputs, 'runs': []}
    output = build / 'results.json'
    def record() -> None:
        output.write_text(json.dumps(results, indent=2) + '\n')
    jobs = []
    # Validate and prepare EVERY selected suite before the first compilation.
    for top, candidate, support, marker, rename in plans:
        source, raw = read_source(ROOT / 'tests' / (top + '.sv'), top, PINS.get(top + '.sv'))
        inputs[str(source)] = hashlib.sha256(raw).hexdigest()
        body = raw.decode('utf-8')
        if rename:
            body = replace_once(body, *rename)
        work = build / top
        work.mkdir()
        tb = work / (top + '.sv')
        tb.write_text(body)
        binary = work / 'simv'
        sources = [candidate] + support + [tb]
        for source in sources:
            inputs[str(source)] = hashlib.sha256(source.read_bytes()).hexdigest()
        compile_argv = vcs + ['-full64', '-sverilog', '-timescale=1ns/1ps',
                              '+define+ARRIA10_ASSERTIONS', '-top', top, '-o', str(binary)]
        compile_argv += a.vcs_arg + (extra if top == 'native_unaligned_head_tb' else [])
        compile_argv += [str(source) for source in sources]
        entry = {'top': top, 'compile_argv': compile_argv, 'simulations': []}
        results['runs'].append(entry)
        jobs.append((top, marker, work, binary, compile_argv, entry))
    record()
    for top, marker, work, binary, compile_argv, entry in jobs:
        if not a.prepare_only:
            code = execute(compile_argv, work / 'compile.log', work)
            entry['compile_returncode'] = code
            record()
            if code or not binary.is_file():
                print(f'FAIL compile {top}: {work / "compile.log"}', file=sys.stderr)
                return 1
        for seed in a.seed or [1, 17, 73]:
            argv = runner + [str(binary), '-no_save', f'+ntb_random_seed={seed}', f'+SEED={seed}'] + a.sim_arg
            run = {'seed': seed, 'argv': argv}
            entry['simulations'].append(run)
            if not a.prepare_only:
                log = work / f'seed_{seed}.log'
                code = execute(argv, log, work)
                text = log.read_text(errors='replace')
                passed = code == 0 and re.search(r'^' + re.escape(marker) + r'\b', text, re.M) is not None
                passed = passed and re.search(r'Fatal:|Error:|Error-\[|UVM_FATAL|assertion.*fail', text, re.I) is None
                run.update(returncode=code, passed=passed)
                record()
                print(f'{"PASS" if passed else "FAIL"} {top} seed={seed}')
                if not passed:
                    return 1
        record()
    print(('PREPARED ONLY; no VCS execution: ' if a.prepare_only else 'VCS suites passed: ') + str(output))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, UnicodeError) as error:
        print(f'INPUT ERROR: {error}', file=sys.stderr)
        raise SystemExit(2)
