#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Run the real controller/native-engine composition, with actual Intel FIFOs.

Supply compatible licensed Quartus models (the observed working family is
23.1std). Model errors are failures even if VCS exits zero. No default timeout,
descriptor cap, RAM cap, global-drain retirement rule, or automatic retry.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TOP = "dma_fetch_composition_v1_tb"
CASES = (
    "mixed", "queued_wrap_order", "fifo_table_credit", "master_partial_drain",
    "abort_partial_drain", "malformed", "unattributable", "status_collision",
    "finite_owner_reuse16321", "fenced_reset_epoch",
)
FAILURE = re.compile(r"Fatal:|Error[!:]|Error-\[|UVM_FATAL|\bassertion\b", re.I)
NONFATAL_ERROR = re.compile(r"Error[!:]|Error-\[|UVM_FATAL|\bassertion\b", re.I)
ORDER_DIAGNOSTIC = re.compile(r"\bEXPECTED_ORDER_VIOLATION expected=(\d+) actual=(\d+)\b")


def load_builder():
    path = ROOT / "tools/build.py"
    spec = importlib.util.spec_from_file_location("composition_builder_for_runner", path)
    if spec is None or spec.loader is None:
        raise ValueError("cannot load the composition builder")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def command(value: str, prepare: bool = False) -> list[str]:
    words = shlex.split(value)
    if not words:
        raise ValueError("empty executable command")
    words[0] = os.path.expanduser(words[0])
    found = shutil.which(words[0])
    if not found and not prepare:
        raise FileNotFoundError(f"executable unavailable: {words[0]}")
    if found:
        # Host dispatch launchers may depend on argv[0]; retain symlink name.
        words[0] = os.path.abspath(found)
    return words


def passed_run(code: int, transcript: str, index: int, name: str) -> bool:
    marker = f"PASS dma-fetch-composition-v1 scenario={index} case={name}"
    lines = re.findall(r"^PASS dma-fetch-composition-v1[^\r\n]*$", transcript, re.M)
    return (code == 0 and len(lines) == 1 and
            re.fullmatch(re.escape(marker) + r"(?: [^\r\n]*)?", lines[0]) is not None and
            FAILURE.search(transcript) is None)


def passed_consumer_run(code: int, transcript: str) -> bool:
    lines = re.findall(r"^PASS consumer-order-v1[^\r\n]*$", transcript, re.M)
    return (code == 0 and lines == ["PASS consumer-order-v1 read=4 write=4 commits=4 receipts=4"]
            and FAILURE.search(transcript) is None)


def witnessed_order_failure(code: int, transcript: str) -> bool:
    """Recognize the deliberate original-RTL witness, never an arbitrary fail."""
    if code not in (0, 1) or NONFATAL_ERROR.search(transcript):
        return False
    if re.search(r"^PASS\b", transcript, re.M):
        return False
    lines = transcript.splitlines()
    fatals = [i for i, line in enumerate(lines) if re.match(r"^\s*Fatal:", line, re.I)]
    matches = list(ORDER_DIAGNOSTIC.finditer(transcript))
    if len(fatals) != 1 or len(matches) != 1 or int(matches[0][1]) == int(matches[0][2]):
        return False
    return any(ORDER_DIAGNOSTIC.search(line) for line in lines[fatals[0]:fatals[0] + 2])


def execute(argv: list[str], log: Path, work: Path) -> int:
    log.with_suffix(".command.json").write_text(json.dumps(argv, indent=2) + "\n")
    with log.open("w", encoding="utf-8") as stream:
        return subprocess.run(argv, cwd=work, stdout=stream,
                              stderr=subprocess.STDOUT, check=False).returncode


def verify_generated(builder, directory: Path, witness: bool) -> dict:
    path = directory / "source_manifest.json"
    manifest = json.loads(builder.read_exact(path))
    expected_variant = "original-order-witness" if witness else "ordered-composition"
    if (manifest.get("format") != builder.FORMAT or
            manifest.get("base_commit") != builder.BASE_COMMIT or
            manifest.get("variant") != expected_variant or
            manifest.get("production_contract_valid") is not False or
            manifest.get("dependency_sha256") != builder.DEPENDENCIES or
            manifest.get("builder_sha256") != builder.sha((ROOT / "tools/build.py").read_bytes())):
        raise ValueError("generated manifest identity, variant, or builder differs")
    builder.verify_dependencies()
    if (manifest.get("compile_sources") != list(builder.SOURCES) or
            manifest.get("include_sources") != list(builder.INCLUDES)):
        raise ValueError("generated source list differs from the declared composition")
    for name in builder.SOURCES + builder.INCLUDES:
        raw = builder.read_exact(directory / name)
        if manifest.get("outputs", {}).get(name) != builder.sha(raw):
            raise ValueError(f"generated source SHA256 mismatch: {name}")
    for relative in ("rtl/dma_fetch_composition_v1.sv", "tests/dma_fetch_composition_v1_tb.sv"):
        raw = builder.read_exact(ROOT / relative)
        if raw != (directory / Path(relative).name).read_bytes():
            raise ValueError(f"public composition source changed since generation: {relative}")
    return manifest


def owned_consumer_sources(builder, witness: bool) -> tuple[dict[str, bytes], dict]:
    """Build only public owned RTL; never substitute this for native composition."""
    upstream = builder.load_v5()
    repair_path = ROOT / "tools/repair.py"
    repair = builder.load_module(repair_path, "composition_runner_order_repair")
    consumer = upstream.consumer()
    if builder.sha(consumer.encode()) != repair.CONSUMER_SHA256:
        raise ValueError("owned consumer seed identity differs")
    if not witness:
        consumer = repair.repair_consumer(consumer)
    package_path = builder.REPO / "experiments/dma-status-v2/rtl/dma_status_v2_pkg.sv"
    bench_path = ROOT / "tests/consumer_order_tb.sv"
    outputs = {
        "dma_status_v2_pkg.sv": builder.read_exact(package_path, builder.DEPENDENCIES[
            "experiments/dma-status-v2/rtl/dma_status_v2_pkg.sv"]),
        "dma_fetch_commit_return_v5.sv": consumer.encode(),
        "consumer_order_tb.sv": builder.read_exact(bench_path),
    }
    manifest = {
        "format": builder.FORMAT, "scope": "owned_consumer_order_only",
        "base_commit": builder.BASE_COMMIT,
        "variant": "original-order-witness" if witness else "ordered-composition",
        "dependency_sha256": builder.DEPENDENCIES,
        "inputs": {str(p): builder.sha(builder.read_exact(p)) for p in (repair_path, bench_path)},
        "outputs": {name: builder.sha(raw) for name, raw in outputs.items()},
        "production_contract_valid": False, "native_vcs_executed": False,
        "rtl_refinement_proved": False,
    }
    return outputs, manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generated", type=Path)
    parser.add_argument("--fifo", type=Path, help="actual source-pinned altpcie_fifo.sv")
    parser.add_argument("--quartus-simlib", type=Path, help="compatible licensed eda/sim_lib")
    parser.add_argument("--vcs", default=os.environ.get("VCS", "vcs"))
    parser.add_argument("--runner", default=os.environ.get("VCS_RUN", "vcs-run"),
                        help="host launcher; --runner= runs simv directly")
    parser.add_argument("--out", type=Path, help="new private build directory outside Git")
    parser.add_argument("--case", action="append", choices=CASES, help="default: every scenario")
    parser.add_argument("--consumer-order-only", action="store_true",
                        help="owned consumer unit fixture only; no private engine/controller inputs")
    parser.add_argument("--expect-order-witness", action="store_true",
                        help="run only scenario1 against --witness-original generated sources")
    parser.add_argument("--prepare-only", action="store_true", help="record commands without executing VCS")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    selected = [(i, name) for i, name in enumerate(CASES) if not args.case or name in args.case]
    if args.consumer_order_only:
        if args.case:
            parser.error("--consumer-order-only has one dedicated fixture; omit --case")
        selected = [(0, "consumer_order")]
    elif args.expect_order_witness:
        if args.case and args.case != [CASES[1]]:
            parser.error("--expect-order-witness allows only --case queued_wrap_order")
        selected = [(1, CASES[1])]
    if args.list:
        print(json.dumps({"planned_only": True, "consumer_order_only": args.consumer_order_only,
                          "expected_negative": args.expect_order_witness,
                          "cases": selected}, indent=2))
        return 0
    try:
        if args.out is None:
            raise ValueError("--out is required")
        if not args.consumer_order_only and None in (args.generated, args.fifo, args.quartus_simlib):
            raise ValueError("--generated, --fifo, --quartus-simlib, and --out are required")
        vcs = command(args.vcs, args.prepare_only)
        runner = command(args.runner, args.prepare_only) if args.runner else []
        if "-no_save" in vcs:
            raise ValueError("-no_save is a simv runtime argument, not a VCS compiler option")
        builder = load_builder()
        if args.consumer_order_only:
            owned, manifest = owned_consumer_sources(builder, args.expect_order_witness)
            inputs = manifest["inputs"]
            out = builder.private_output(args.out, [ROOT])
            generated = out / "owned_sources"
            manifest_raw = (json.dumps(manifest, indent=2) + "\n").encode()
            sources = [generated / name for name in owned]
            top = "consumer_order_tb"
        else:
            owned = None
            generated = args.generated.expanduser().resolve()
            manifest = verify_generated(builder, generated, args.expect_order_witness)
            manifest_raw = (generated / "source_manifest.json").read_bytes()
            fifo = args.fifo.expanduser().resolve()
            inputs = {str(fifo): builder.sha(builder.read_exact(fifo, builder.FIFO_SHA))}
            models = []
            for name in ("altera_mf.v", "220model.v"):
                path = (args.quartus_simlib / name).expanduser().resolve()
                # Vendor model comments may use legacy encodings; compile and
                # fingerprint original bytes without decoding or rewriting them.
                raw = path.read_bytes()
                if not raw:
                    raise ValueError(f"empty simulation model: {path}")
                inputs[str(path)] = builder.sha(raw)
                models.append(path)
            out = builder.private_output(args.out, [ROOT, generated, fifo, *models])
            sources = [generated / name for name in builder.SOURCES[:-1]]
            sources += [fifo, *models, generated / builder.SOURCES[-1]]
            top = TOP
    except FileNotFoundError as error:
        print(f"UNAVAILABLE: {error}; no native compile or simulation executed", file=sys.stderr)
        return 77
    except (OSError, ValueError, KeyError, UnicodeError) as error:
        print(f"INPUT ERROR: {error}; no native compile or simulation executed", file=sys.stderr)
        return 2
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    if owned is not None:
        generated.mkdir()
        for name, raw in owned.items():
            (generated / name).write_bytes(raw)
        (generated / "source_manifest.json").write_bytes(manifest_raw)
    binary = out / "simv"
    # Compile the package first and the testbench last; native FIFO/model files
    # remain original licensed inputs. There is no behavioral FIFO substitute.
    compile_argv = vcs + ["-full64", "-sverilog", "-timescale=1ns/1ps", "-top", top,
                          "+incdir+" + str(generated), "-o", str(binary)] + [str(p) for p in sources]
    runtime = [(index, name, runner + [str(binary), "-no_save"] +
                ([] if args.consumer_order_only else [f"+SCENARIO={index}"]))
               for index, name in selected]
    report = {
        "format": builder.FORMAT, "base_commit": builder.BASE_COMMIT,
        "scope": "owned_consumer_order_only" if args.consumer_order_only else "native_controller_fetch_composition",
        "variant": manifest["variant"], "inputs": inputs,
        "source_manifest_sha256": builder.sha(manifest_raw),
        "runner_sha256": builder.sha(Path(__file__).read_bytes()),
        "native_compile_executed": False, "native_simulation_executed": False,
        "production_contract_valid": False, "rtl_refinement_proved": False, "results": [],
    }

    def record() -> None:
        temporary = out / "results.json.tmp"
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(out / "results.json")

    (out / "commands.json").write_text(json.dumps({"compile": compile_argv,
        "runs": [{"scenario": i, "case": n, "argv": argv} for i, n, argv in runtime]}, indent=2) + "\n")
    record()
    if args.prepare_only:
        print(f"PREPARED ONLY: {out}; no native compile or simulation executed")
        return 0
    compile_log = out / "compile.log"
    try:
        rc = execute(compile_argv, compile_log, out)
    except OSError as error:
        report["results"].append({"stage": "compile_launch", "passed": False, "error": str(error)})
        record()
        print(f"UNAVAILABLE: compiler launch failed: {error}", file=sys.stderr)
        return 77
    report["native_compile_executed"] = True
    transcript = compile_log.read_text(errors="replace")
    compiled = rc == 0 and binary.is_file() and FAILURE.search(transcript) is None
    report["results"].append({"stage": "compile", "returncode": rc, "passed": compiled})
    record()
    if not compiled:
        print(f"FAIL compile: {compile_log}", file=sys.stderr)
        return 1
    for index, name, argv in runtime:
        log = out / (name + ".log")
        try:
            rc = execute(argv, log, out)
        except OSError as error:
            report["results"].append({"stage": "simulation_launch", "scenario": index,
                                      "case": name, "passed": False, "error": str(error)})
            record()
            print(f"UNAVAILABLE: simulator launch failed: {error}", file=sys.stderr)
            return 77
        report["native_simulation_executed"] = True
        transcript = log.read_text(errors="replace")
        passed = (witnessed_order_failure(rc, transcript) if args.expect_order_witness
                  else passed_consumer_run(rc, transcript) if args.consumer_order_only
                  else passed_run(rc, transcript, index, name))
        report["results"].append({"stage": "simulation", "scenario": index, "case": name,
            "returncode": rc, "passed": passed, "expected_negative": args.expect_order_witness})
        record()
        verdict = "EXPECTED NEGATIVE OBSERVED" if passed and args.expect_order_witness else "PASS" if passed else "FAIL"
        print(f"{verdict} {name}: {log}")
    return 0 if all(row["passed"] for row in report["results"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
