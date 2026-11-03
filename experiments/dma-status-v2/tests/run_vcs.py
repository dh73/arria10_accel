#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Compile and execute candidate-v2 regressions using VCS, never a substitute.

Generated sources are explicit inputs. This runner does not modify or search
an immutable qualification tree, select hardware, or assert shell readiness.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def cases() -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for count in (1, 2, 4, 8):
        for mode in range(6):
            result.append({"name": f"payload_n{count}_mode{mode}",
                           "top": "read_dma_candidate_v2_tb",
                           "args": ["+SCENARIO=0", f"+N={count}", f"+MODE={mode}"]})
    for count in (1, 16):
        result.append({"name": f"master_disabled_n{count}",
                       "top": "read_dma_candidate_v2_tb",
                       "args": ["+SCENARIO=1", f"+N={count}"]})
    for scenario, name in ((2, "reused_id"), (3, "fetch_ids"),
                           (4, "last_payload_and_control_error"),
                           (5, "pause_resume"), (6, "abort_then_payload"),
                           (7, "flush_queued_ids")):
        result.append({"name": name, "top": "read_dma_candidate_v2_tb",
                       "args": [f"+SCENARIO={scenario}"]})
    result.append({"name": "sink", "top": "dma_status_sink_v2_tb", "args": []})
    result.append({"name": "owner", "top": "dma_owner_v2_tb", "args": []})
    for desc_id in (7, 128, 192):
        result.append({"name": f"engine_controller_error_id{desc_id}",
                       "top": "read_dma_controller_v2_tb", "args": [f"+ID={desc_id}"]})
    return result


def checked_file(value: str | None, name: str) -> Path:
    if not value:
        raise ValueError(f"{name} is required for the selected suite")
    path = Path(value).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"{name} is not a readable file: {path}")
    return path


def tool_command(value: str, name: str) -> list[str]:
    parts = shlex.split(value)
    if not parts or not shutil.which(parts[0]):
        raise FileNotFoundError(f"{name} executable unavailable: {parts[0] if parts else value}")
    return parts


def execute(command: list[str], log: Path, cwd: Path, timeout: int | None) -> int:
    log.parent.mkdir(parents=True, exist_ok=True)
    # A command record supports reproducibility; it is not a claim of success.
    log.with_suffix(log.suffix + ".command.json").write_text(json.dumps(command, indent=2) + "\n")
    with log.open("w", encoding="utf-8") as output:
        try:
            completed = subprocess.run(command, cwd=cwd, stdout=output,
                                       stderr=subprocess.STDOUT, timeout=timeout,
                                       check=False)
        except subprocess.TimeoutExpired:
            output.write("\nRUNNER TIMEOUT; test did not complete.\n")
            return 124
    return completed.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", help="generated altpcieav_dma_rd_candidate_v2.sv")
    parser.add_argument("--controller", help="generated altpcie_dynamic_control_candidate_v2.sv")
    parser.add_argument("--fifo", help="original supplied altpcie_fifo.sv, read only")
    parser.add_argument("--quartus-simlib", help="Quartus 23.1 standard eda/sim_lib directory")
    parser.add_argument("--build-dir", default=str(ROOT / "build" / "vcs"))
    parser.add_argument("--vcs", default=os.environ.get("VCS", "vcs"), help="VCS compile command prefix")
    parser.add_argument("--runner", default=os.environ.get("VCS_RUN", "vcs-run"),
                        help="simulation wrapper command prefix; use --runner= for direct VCS simv")
    parser.add_argument("--suite", choices=("all", "engine", "sink", "owner", "controller"), default="all")
    parser.add_argument("--list", action="store_true", help="print planned cases without invoking VCS")
    parser.add_argument("--compile-timeout", type=int, default=None)
    parser.add_argument("--run-timeout", type=int, default=None)
    args = parser.parse_args()
    selected = cases()
    tops = {"engine": "read_dma_candidate_v2_tb", "sink": "dma_status_sink_v2_tb",
            "owner": "dma_owner_v2_tb", "controller": "read_dma_controller_v2_tb"}
    if args.suite != "all":
        selected = [case for case in selected if case["top"] == tops[args.suite]]
    if args.list:
        print(json.dumps({"planned_only": True, "cases": selected}, indent=2))
        return 0
    try:
        vcs = tool_command(args.vcs, "VCS")
        runner = tool_command(args.runner, "VCS runner") if args.runner else []
        sources = [ROOT / "rtl" / "dma_status_v2_pkg.sv", ROOT / "rtl" / "dma_status_sink_v2.sv"]
        if args.suite != "sink":
            sources += [ROOT / "rtl" / "dma_owner_v2.sv"]
        if args.suite not in ("sink", "owner"):
            sources += [checked_file(args.engine, "--engine"), checked_file(args.fifo, "--fifo")]
            library = Path(args.quartus_simlib or "").expanduser().resolve()
            if not args.quartus_simlib:
                raise ValueError("--quartus-simlib is required for vendor RAM/LPM models")
            sources += [checked_file(str(library / "altera_mf.v"), "altera_mf.v"),
                        checked_file(str(library / "220model.v"), "220model.v")]
        if args.suite in ("all", "controller"):
            sources.append(checked_file(args.controller, "--controller"))
        for source in sources:
            checked_file(str(source), str(source))
    except FileNotFoundError as error:
        print(f"UNAVAILABLE: {error}; no VCS regression executed", file=sys.stderr)
        return 77
    except ValueError as error:
        print(f"INPUT ERROR: {error}", file=sys.stderr)
        return 2
    build = Path(args.build_dir).expanduser().resolve()
    build.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, object]] = []
    binaries: dict[str, Path] = {}
    for top in dict.fromkeys(str(case["top"]) for case in selected):
        work = build / top
        work.mkdir(parents=True, exist_ok=True)
        binary = work / "simv"
        command = vcs + ["-full64", "-sverilog", "-timescale=1ns/1ps",
                         "+incdir+" + str(ROOT / "rtl"),
                         "-top", top, "-o", str(binary)]
        command += [str(path) for path in sources]
        command.append(str(ROOT / "tests" / f"{top}.sv"))
        code = execute(command, work / "compile.log", work, args.compile_timeout)
        results.append({"stage": "compile", "top": top, "returncode": code})
        if code != 0 or not binary.is_file():
            (build / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"FAIL compile {top}; see {work / 'compile.log'}", file=sys.stderr)
            return 1
        binaries[top] = binary
    failed = False
    for case in selected:
        name, top = str(case["name"]), str(case["top"])
        work = build / top
        log = work / f"{name}.log"
        command = runner + [str(binaries[top])] + list(case["args"])
        code = execute(command, log, work, args.run_timeout)
        transcript = log.read_text(encoding="utf-8", errors="replace")
        passed = code == 0 and "PASS " in transcript and "Fatal:" not in transcript and "Error:" not in transcript
        results.append({"stage": "simulate", "case": name, "returncode": code, "passed": passed})
        print(f"{'PASS' if passed else 'FAIL'} {name}")
        failed |= not passed
    (build / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
