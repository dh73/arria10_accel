#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Native producer regression.

Completion packets are host stimuli; producer/owner/FIFOs/route/consumer/sink
are real source-pinned implementations. D2H table delivery is covered; the
separate D2H data-mover/DDR/packetizer path is outside this suite.
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
CASES = (
    "mixed_interleaved_split_backpressure_reuse",
    "master_partial_drain", "abort_partial_drain", "wrong_route",
    "wrong_ordinal_base", "wrong_dts_ordinal", "late_status",
    "late_payload_status_veto", "full_token_recurrence260",
    "explicit_fenced_reset_new_epoch", "stale_return_epoch",
    "no_data_error_retains_debt", "premature_last_completion",
    "tag_reuse_with_older_stalled_commands",
)
GENERATED = (
    "dma_owner_fetch_return_v5.sv", "altpcieav_dma_rd_fetch_return_v5.sv",
    "dma_fetch_commit_return_v5.sv", "dma_status_sink_fetch_v4.sv",
    "dma_fetch_return_route_v5.sv",
)
INCLUDES = ("engine_fetch_return_v5.svh", "engine_v2_declarations.svh",
            "engine_return_declarations_v5.svh", "engine_return_v5.svh")


def existing(path):
    path = Path(path).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"missing file: {path}")
    return path


def executable(value):
    words = shlex.split(value)
    if not words or not shutil.which(words[0]):
        raise FileNotFoundError(f"executable unavailable: {words[0] if words else value}")
    return words


def execute(argv, log, work):
    log.with_suffix(".command.json").write_text(json.dumps(argv, indent=2) + "\n")
    with log.open("w", encoding="utf-8") as stream:
        return subprocess.run(argv, cwd=work, stdout=stream,
                              stderr=subprocess.STDOUT, check=False).returncode


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--generated", type=Path, help="new output of v5 tools/build.py")
    p.add_argument("--fifo", type=Path, help="original altpcie_fifo.sv")
    p.add_argument("--quartus-simlib", type=Path, help="actual Quartus eda/sim_lib")
    p.add_argument("--vcs", default=os.environ.get("VCS", "vcs"))
    p.add_argument("--runner", default=os.environ.get("VCS_RUN", "vcs-run"),
                   help="host launcher; --runner= executes simv directly")
    p.add_argument("--out", type=Path, help="new isolated build directory")
    p.add_argument("--case", action="append", choices=CASES, help="default: all cases")
    p.add_argument("--list", action="store_true")
    a = p.parse_args()
    selected = [(i, name) for i, name in enumerate(CASES) if not a.case or name in a.case]
    if a.list:
        print(json.dumps({"planned_only": True, "cases": selected}, indent=2))
        return 0
    try:
        vcs = executable(a.vcs)
        runner = executable(a.runner) if a.runner else []
        if a.generated is None or a.fifo is None or a.quartus_simlib is None:
            raise ValueError("--generated, --fifo, and --quartus-simlib are required")
        if a.out is None or a.out.exists():
            raise ValueError("--out must name a new isolated directory")
        generated = a.generated.resolve()
        manifest = json.loads(existing(generated / "source_manifest.json").read_text())
        if manifest.get("format") != "dma-fetch-return-v5":
            raise ValueError("generated manifest format mismatch")
        for name in GENERATED + INCLUDES:
            raw = existing(generated / name).read_bytes()
            if manifest.get("outputs", {}).get(name) != hashlib.sha256(raw).hexdigest():
                raise ValueError(f"generated source SHA256 mismatch: {name}")
        sources = [existing(ROOT.parent / "dma-status-v2/rtl/dma_status_v2_pkg.sv")]
        sources += [existing(generated / name) for name in GENERATED]
        sources += [existing(a.fifo)]
        sources += [existing(a.quartus_simlib / name) for name in ("altera_mf.v", "220model.v")]
        sources += [existing(ROOT / "tests/native_return_tb.sv")]
    except FileNotFoundError as error:
        print(f"UNAVAILABLE: {error}; no VCS compile/simulation executed", file=sys.stderr)
        return 77
    except (OSError, ValueError, KeyError) as error:
        print(f"INPUT ERROR: {error}", file=sys.stderr)
        return 2
    out = a.out.resolve()
    out.mkdir(parents=True)
    binary = out / "simv"
    compile_argv = vcs + ["-full64", "-sverilog", "-timescale=1ns/1ps", "-top", "native_return_tb",
                          "+incdir+" + str(generated), "+incdir+" + str(ROOT / "rtl"), "-o", str(binary)]
    compile_argv += list(map(str, sources))
    results = []

    def record(row):
        results.append(row)
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")

    rc = execute(compile_argv, out / "compile.log", out)
    record({"stage": "compile", "returncode": rc})
    if rc != 0 or not binary.is_file() or re.search(
            r"Fatal:|Error[!:]|Error-\[|UVM_FATAL", (out / "compile.log").read_text(errors="replace"), re.IGNORECASE):
        print(f"FAIL compile: {out / 'compile.log'}", file=sys.stderr)
        return 1
    for index, name in selected:
        log = out / (name + ".log")
        rc = execute(runner + [str(binary), "-no_save", f"+SCENARIO={index}"], log, out)
        transcript = log.read_text(errors="replace")
        passed = rc == 0 and "PASS native-return-v5 " in transcript and not re.search(
            r"Fatal:|Error[!:]|Error-\[|UVM_FATAL|assertion.*fail", transcript, re.IGNORECASE)
        record({"stage": "simulation", "case": name, "returncode": rc, "passed": passed})
        print(f"{'PASS' if passed else 'FAIL'} {name}")
    return 0 if all(row.get("passed", True) for row in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
