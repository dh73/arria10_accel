#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Run v3 reuse tests and explicitly derived v2 integration cases with VCS only.

No hardware access, automatic retry, simulation substitute, or runtime cap.
The original candidate-v2 37-case runner and all its sources remain unchanged.
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

from adapt_v2_tests import adapt_engine, adapt_controller

ROOT = Path(__file__).resolve().parents[1]


def cases() -> list[dict]:
    names = ("continuous_reuse_12256", "held_and_duplicate_ack", "stale_generation_ack",
             "changed_held_ack", "ack_before_delivery", "malformed_ack", "foreign_id_ack",
             "wrong_head_ack", "same_edge_error_full_queue_quarantine",
             "withdrawal_edge_external_fault")
    result = [{"name": name, "top": "dma_reuse_v3_tb", "suite": "reuse",
               "args": [f"+SCENARIO={i}"]} for i, name in enumerate(names)]
    for count in (1, 2, 4, 8):
        for mode in range(6):
            result.append({"name": f"payload_n{count}_mode{mode}", "suite": "engine",
                           "top": "read_dma_candidate_v3_tb",
                           "args": ["+SCENARIO=0", f"+N={count}", f"+MODE={mode}"]})
    for count in (1, 16):
        result.append({"name": f"master_disabled_n{count}", "suite": "engine",
                       "top": "read_dma_candidate_v3_tb", "args": ["+SCENARIO=1", f"+N={count}"]})
    for scenario, name in ((2, "reused_id"), (3, "fetch_ids"), (4, "last_payload_and_control_error"),
                           (5, "pause_resume"), (6, "abort_then_payload"), (7, "flush_queued_ids")):
        result.append({"name": name, "suite": "engine", "top": "read_dma_candidate_v3_tb",
                       "args": [f"+SCENARIO={scenario}"]})
    for desc_id in (7, 128, 192):
        result.append({"name": f"engine_controller_error_id{desc_id}", "suite": "controller",
                       "top": "read_dma_controller_v3_tb", "args": [f"+ID={desc_id}"]})
    result.append({"name": "actual_controller_receipt", "suite": "controller",
                   "top": "dma_controller_receipt_v3_tb", "args": []})
    return result


def checked_file(value: str | Path | None, label: str) -> Path:
    if not value:
        raise ValueError(f"{label} is required for the selected suite")
    path = Path(value).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"{label} is not a readable file: {path}")
    return path


def command(value: str, label: str) -> list[str]:
    words = shlex.split(value)
    if not words or not shutil.which(words[0]):
        raise FileNotFoundError(f"{label} executable unavailable: {words[0] if words else value}")
    return words


def execute(argv: list[str], log: Path, work: Path) -> int:
    log.with_suffix(log.suffix + ".command.json").write_text(json.dumps(argv, indent=2) + "\n")
    with log.open("w", encoding="utf-8") as stream:
        return subprocess.run(argv, cwd=work, stdout=stream, stderr=subprocess.STDOUT, check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=("all", "reuse", "engine", "controller"), default="all")
    parser.add_argument("--v2-root", default=str(ROOT.parent / "dma-status-v2"))
    parser.add_argument("--engine", help="source-bound generated v3 read engine")
    parser.add_argument("--controller", help="source-bound generated v3 controller")
    parser.add_argument("--fifo", help="unchanged qualified vendor FIFO")
    parser.add_argument("--quartus-simlib", help="Quartus23.1std eda/sim_lib")
    parser.add_argument("--vcs", default=os.environ.get("VCS", "vcs"))
    parser.add_argument("--runner", default=os.environ.get("VCS_RUN", "vcs-run"),
                        help="VCS execution wrapper; --runner= invokes compiled simv directly")
    parser.add_argument("--build-dir", default=str(ROOT / "build" / "vcs"))
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    selected = [case for case in cases() if args.suite == "all" or case["suite"] == args.suite]
    if args.list:
        print(json.dumps({"planned_only": True, "cases": selected}, indent=2))
        return 0
    try:
        vcs = command(args.vcs, "VCS")
        runner = command(args.runner, "VCS runner") if args.runner else []
        v2 = Path(args.v2_root).expanduser().resolve()
        sources = [checked_file(v2 / "rtl" / "dma_status_v2_pkg.sv", "v2 package"),
                   checked_file(ROOT / "rtl" / "dma_owner_v3.sv", "v3 owner"),
                   checked_file(ROOT / "rtl" / "dma_status_sink_v3.sv", "v3 sink")]
        integration = args.suite != "reuse"
        tests = {"dma_reuse_v3_tb": (ROOT / "tests" / "dma_reuse_v3_tb.sv").read_text()}
        if integration:
            sources += [checked_file(args.engine, "--engine"), checked_file(args.fifo, "--fifo")]
            if not args.quartus_simlib:
                raise ValueError("--quartus-simlib is required for vendor RAM/LPM models")
            models = Path(args.quartus_simlib).expanduser().resolve()
            sources += [checked_file(models / "altera_mf.v", "altera_mf.v"),
                        checked_file(models / "220model.v", "220model.v")]
        if args.suite in ("all", "engine"):
            tests["read_dma_candidate_v3_tb"] = adapt_engine(checked_file(v2 / "tests" / "read_dma_candidate_v2_tb.sv", "v2 engine TB"))
        if args.suite in ("all", "controller"):
            sources.append(checked_file(args.controller, "--controller"))
            tests["read_dma_controller_v3_tb"] = adapt_controller(checked_file(v2 / "tests" / "read_dma_controller_v2_tb.sv", "v2 controller TB"))
            tests["dma_controller_receipt_v3_tb"] = checked_file(ROOT / "tests" / "dma_controller_receipt_v3_tb.sv", "v3 controller receipt TB").read_text()
    except FileNotFoundError as error:
        print(f"UNAVAILABLE: {error}; no VCS compile or simulation executed", file=sys.stderr)
        return 77
    except (ValueError, UnicodeError) as error:
        print(f"INPUT ERROR: {error}", file=sys.stderr)
        return 2
    build = Path(args.build_dir).expanduser().resolve()
    build.mkdir(parents=True, exist_ok=True)
    results = []
    binaries = {}
    for top in dict.fromkeys(case["top"] for case in selected):
        work = build / top
        work.mkdir(parents=True, exist_ok=True)
        test = work / f"{top}.sv"
        test.write_text(tests[top])
        binary = work / "simv"
        argv = vcs + ["-full64", "-sverilog", "-timescale=1ns/1ps",
                      "+incdir+" + str(ROOT / "rtl"), "+incdir+" + str(v2 / "rtl"),
                      "-top", top, "-o", str(binary)] + [str(p) for p in sources] + [str(test)]
        code = execute(argv, work / "compile.log", work)
        results.append({"stage": "compile", "top": top, "returncode": code})
        if code != 0 or not binary.is_file():
            (build / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"FAIL compile {top}; see {work / 'compile.log'}", file=sys.stderr)
            return 1
        binaries[top] = binary
    for case in selected:
        work = build / case["top"]
        log = work / f"{case['name']}.log"
        code = execute(runner + [str(binaries[case["top"]])] + case["args"], log, work)
        transcript = log.read_text(encoding="utf-8", errors="replace")
        passed = code == 0 and "PASS " in transcript and not re.search(r"Fatal:|Error:|Error-\[|UVM_FATAL", transcript)
        results.append({"stage": "simulate", "case": case["name"], "returncode": code, "passed": passed})
        print(f"{'PASS' if passed else 'FAIL'} {case['name']}")
    (build / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(item.get("passed", True) for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
