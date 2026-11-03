#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""VCS-only fetch consumer/controller tests; no runtime/resource caps or retries.

Controller suites compile the actual source-checked generated controllers and
Quartus FIFO models. They never substitute an abstract controller or FIFO.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def cases(suite):
    result = []
    if suite in ('core', 'all'):
        result += [('dma_fetch_commit_v4_tb', 'interleaving_reuse320', ['+SCENARIO=0']),
                   ('dma_fetch_commit_v4_tb', 'pause_terminal_error', ['+SCENARIO=1'])]
        names = ('duplicate', 'wrong_generation', 'wrong_route', 'out_of_range',
                 'wrong_descriptor_id', 'late_payload', 'partial_close', 'error_close',
                 'foreign_status', 'invalid_bind', 'stale_epoch', 'epoch_change', 'zero_count')
        result += [('dma_fetch_commit_v4_tb', n, ['+SCENARIO=2', f'+KIND={k}'])
                   for k, n in enumerate(names)]
        result += [('dma_fetch_commit_v4_tb', 'abort_commit_race', ['+SCENARIO=3']),
                   ('dma_fetch_commit_v4_tb', 'reset_epoch', ['+SCENARIO=4']),
                   ('dma_fetch_commit_v4_tb', 'full128_tables', ['+SCENARIO=5']),
                   ('dma_fetch_commit_v4_tb', 'delayed_bind_held_traffic', ['+SCENARIO=6']),
                   ('dma_fetch_commit_v4_tb', 'partial_error_independent_progress', ['+SCENARIO=7']),
                   ('dma_fetch_commit_v4_tb', 'full_token_recurrence256', ['+SCENARIO=8'])]
        result += [('dma_fetch_commit_v4_tb', n, ['+SCENARIO=9', f'+KIND={k}'])
                   for k, n in enumerate(('receipt_wrong_token', 'receipt_missing_low_phase',
                                          'receipt_changed_held_word'))]
    if suite in ('controller', 'all'):
        result += [('dma_controller_fetch_v4_tb', 'actual_dcs_dts_tx_receipts', ['+SCENARIO=0']),
                   ('dma_controller_fetch_v4_tb', 'actual_partial_error_late_data', ['+SCENARIO=1']),
                   ('dma_controller_fetch_v4_tb', 'actual_pending_doorbell_supersession', ['+SCENARIO=2']),
                   ('dma_controller_fetch_v4_tb', 'actual_busy_fetch_credit_allows_fifo_progress', ['+SCENARIO=3'])]
    if suite in ('write', 'all'):
        result += [('dma_write_controller_fetch_v4_tb', 'actual_write_snapshot_stalls', [])]
    return result


def executable(value):
    words = shlex.split(value)
    if not words or not shutil.which(words[0]):
        raise FileNotFoundError(f'executable unavailable: {words[0] if words else value}')
    return words


def existing(path):
    path = Path(path).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f'missing input file: {path}')
    return path


def execute(argv, log, work):
    log.with_suffix('.command.json').write_text(json.dumps(argv, indent=2) + '\n')
    with log.open('w', encoding='utf-8') as stream:
        return subprocess.run(argv, cwd=work, stdout=stream,
                              stderr=subprocess.STDOUT, check=False).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=('core', 'controller', 'write', 'all'), default='all')
    parser.add_argument('--generated', type=Path, help='new output directory of tools/build.py')
    parser.add_argument('--quartus-simlib', type=Path, help='licensed Quartus eda/sim_lib directory')
    parser.add_argument('--fifo', type=Path, help='unchanged licensed altpcie_fifo.sv, required for legacy write status path')
    parser.add_argument('--vcs', default=os.environ.get('VCS', 'vcs'))
    parser.add_argument('--runner', default=os.environ.get('VCS_RUN', 'vcs-run'),
                        help='execution wrapper; --runner= runs the compiled simv directly')
    parser.add_argument('--out', type=Path, help='new isolated build directory, never reused')
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()
    selected = cases(args.suite)
    if args.list:
        print(json.dumps({'planned_only': True, 'cases': selected}, indent=2))
        return 0
    try:
        vcs = executable(args.vcs)
        runner = executable(args.runner) if args.runner else []
        if args.out is None or args.out.exists():
            raise ValueError('--out must name a new isolated directory')
        package = existing(ROOT.parent / 'dma-status-v2/rtl/dma_status_v2_pkg.sv')
        core = existing(ROOT / 'rtl/dma_fetch_commit_v4.sv')
        sources = {'dma_fetch_commit_v4_tb': [package, core]}
        if args.suite != 'core':
            if args.generated is None or args.quartus_simlib is None:
                raise ValueError('controller/write suites require --generated and --quartus-simlib')
            generated = args.generated.resolve()
            models = [existing(args.quartus_simlib / 'altera_mf.v'),
                      existing(args.quartus_simlib / '220model.v')]
            if args.suite in ('controller', 'all'):
                sources['dma_controller_fetch_v4_tb'] = [package, core,
                    existing(generated / 'dma_status_sink_fetch_v4.sv'),
                    existing(generated / 'dma_owner_fetch_v4.sv'),
                    existing(generated / 'altpcie_dynamic_control_fetch_v4.sv')] + models
            if args.suite in ('write', 'all'):
                if args.fifo is None:
                    raise ValueError('write suite requires --fifo for unchanged legacy status FIFO')
                sources['dma_write_controller_fetch_v4_tb'] = [
                    existing(generated / 'altpcie_dynamic_control_write_v4.sv'), existing(args.fifo)] + models
    except FileNotFoundError as error:
        print(f'UNAVAILABLE: {error}; no VCS compile/simulation executed', file=sys.stderr)
        return 77
    except ValueError as error:
        print(f'INPUT ERROR: {error}', file=sys.stderr)
        return 2
    out = args.out.resolve()
    out.mkdir(parents=True)
    results = []
    binaries = {}
    for top in dict.fromkeys(c[0] for c in selected):
        work = out / top
        work.mkdir()
        binary = work / 'simv'
        argv = vcs + ['-full64', '-sverilog', '-timescale=1ns/1ps',
                      '+incdir+' + str(ROOT / 'rtl'), '-top', top, '-o', str(binary)]
        argv += [str(p) for p in sources[top]] + [str(existing(ROOT / 'tests' / (top + '.sv')))]
        rc = execute(argv, work / 'compile.log', work)
        results.append({'stage': 'compile', 'top': top, 'returncode': rc})
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        if rc != 0 or not binary.is_file():
            print(f'FAIL compile {top}: {work / "compile.log"}', file=sys.stderr)
            return 1
        binaries[top] = binary
    for top, name, options in selected:
        work = out / top
        log = work / (name + '.log')
        rc = execute(runner + [str(binaries[top])] + options, log, work)
        transcript = log.read_text(errors='replace')
        passed = rc == 0 and 'PASS ' in transcript and not re.search(
            r'Fatal:|Error:|Error-\[|UVM_FATAL', transcript)
        results.append({'stage': 'simulation', 'case': name, 'returncode': rc, 'passed': passed})
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(f'{"PASS" if passed else "FAIL"} {name}')
    return 0 if all(r.get('passed', True) for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
