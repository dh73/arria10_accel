#!/usr/bin/env python3
"""Build and run the isolated D2H controller composition with VCS only.

Supply actual private inputs and the compatible Quartus 23.1 standard simulation
models. No generated vendor RTL is published. --prepare-only performs source
checks and writes commands but does not compile, simulate, or prove anything.
There are no execution timeouts, descriptor-length limits, or simulator retries.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BASE_COMMIT = "570167571021e0ae59ac4893c478933694011599"
TOP = "d2h_composition_tb"
PASS = "D2H_COMPOSITION_PASS"
# suite: (controller variant, testbench CASE, expected native fatal or None)
SUITES = {
    "capacity-witness": ("original", "capacity-witness", "D2H_ORIGINAL_STATUS_CAPACITY"),
    "failure-witness": ("original", "failure-witness", "D2H_ORIGINAL_FALSE_SUCCESS"),
    "base-witness": ("original", "base-witness", "D2H_ORIGINAL_BASE_RETARGET"),
    "stress": ("corrected", "stress", None),
    "failure": ("corrected", "failure", None),
    "reset": ("corrected", "reset", None),
    "selective": ("corrected", "selective", None),
}
PRODUCER_ORIGINAL = "9658fce313dc40ea278021747923137a9cad5fc3df344ecc6818e63e010aef54"
PRODUCER_CORRECTED = "5a6eb7dc706e78098481b7c5e11b77460c580831ba6ab2f8b9cca13626adbadd"
PRIVATE_PINS = {
    "controller": ("019de60946a09d16053a8cf15148a5fcbea700b1f4c9c44fd12e0485cbdabd65",),
    "payload": ("a7a66662e3d15497cf24ade5ce672733104eadbeb670175b542adab6c409c06c",
                "399ac47d8137c3d175b30ffcf90cd405fd3d91edd0a6bb3c79f16ecb9200923d"),
    "mux": ("e7d1a716558f273876ae5ec8f98f6a83f98b79e793e5ed07e42eaba3e2f7cb3b",),
    "producer": (PRODUCER_ORIGINAL, PRODUCER_CORRECTED),
    "fifo": ("8270ffb30fa3b75eaefd6d3d403335f04dbb0f13c894d35e9f6a6668f29f4bf8",),
    "wrapper": ("5faf8d9c622e7aeff2f3f77b94e3dddd9b6cac17272892a8b5493412986ee4fe",),
    "aligner": ("792d039c00e605df32157b7de48e749ea6c1343639832527aa170e3100b344fa",),
    "tlpgen": ("c4a38772eec21339f84a1a9e183e111302d0263693e1e230ba1171bab7b7a01f",),
}
# Exact fetched owned bytes, including every transitive predecessor transformer.
# Do not relax these pins to accept a newer branch or normalize CR/CRLF.
OWNED_PINS = {
    "experiments/dma-fetch-v4/rtl/controller_tx_v4.svh":
        "dd0291be6e02508db0243112552451de33bc4d82a08487c60f8bd10a0a851fa1",
    "experiments/dma-status-v3/tests/native_d2h_packetizer_tb.sv":
        "3e03653094556f636567938df606c3b009b071e7b0c14dff8e6110bd995323e6",
    "experiments/dma-status-v3/rtl/dma_memory_path_unaligned_candidate.sv":
        "aaee933244cdc65f1581daf6ce24c3ee7b73c6af4624c98a40d7faf03948f743",
    "experiments/dma-status-v3/tools/build_payload_unaligned.py":
        "79ff4bddf2c9bb34ba2d9d9df9f4f2cced6f07b12fab00f43873a7b3a6632e03",
    "experiments/dma-status-v3/tools/build_payload_mask.py":
        "15fa3e4bc375d09c2fab7097d49cb6577065064392c99c2fc52141f8129bccef",
    "experiments/dma-status-v3/tools/build_control_wrapper.py":
        "ef50add2e6af64d94970e1be1d1cbea2e5bcdcf73ea380600a5a28e0078619dd",
    "experiments/dma-status-v3/tools/build_readmem_count.py":
        "728099cd06073b2e1a626537db7d5aed786e112e549ca0e8f684d56e9ccfdbcc",
    "experiments/dma-status-v3/tools/build_packetizer.py":
        "d4df0fa32bfa9c4ad8347ac9da2418325e062f09b545b67680e5151e2e9165b9",
}
INCLUDES = ("controller_retirement_v1.svh", "composition_io.svh", "composition_stimulus.svh")
WITNESS_DIAGNOSTICS = {
    "D2H_ORIGINAL_STATUS_CAPACITY": r"\bD2H_ORIGINAL_STATUS_CAPACITY\s+count=128\b",
    "D2H_ORIGINAL_FALSE_SUCCESS": r"\bD2H_ORIGINAL_FALSE_SUCCESS\s+data=00000001\b",
    "D2H_ORIGINAL_BASE_RETARGET": r"\bD2H_ORIGINAL_BASE_RETARGET\s+address=[0-9a-fA-F]{16}\b",
}
ERRORS = re.compile(
    r"Error[!:]|Error-\[|UVM_(?:ERROR|FATAL)|assertion[^\r\n]*(?:fail|error)|"
    r"segmentation fault|bus error|core dumped|internal (?:compiler )?error",
    re.IGNORECASE,
)


class UnavailableTool(Exception):
    pass


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def read_source(value: str | Path, label: str, pins: tuple[str, ...] = ()) -> tuple[Path, bytes]:
    path = Path(value).expanduser().resolve()
    raw = path.read_bytes()
    if not raw or (pins and sha(raw) not in pins):
        raise ValueError(f"{label}: empty or changed source; SHA256={sha(raw)}: {path}")
    return path, raw


def passed_compile(code: int, log: str, binary_exists: bool) -> bool:
    # Some launchers return zero after model diagnostics or $fatal.
    return (code == 0 and binary_exists and ERRORS.search(log) is None
            and re.search(r"Fatal:", log, re.I) is None)


def passed_run(code: int, log: str, case: str, expected_fatal: str | None = None) -> bool:
    if code < 0 or ERRORS.search(log):
        return False
    pass_lines = re.findall(r"^" + PASS + r"\b[^\r\n]*", log, re.M)
    if expected_fatal is None:
        return (code == 0 and len(pass_lines) == 1
                and re.match(r"^" + PASS + r" case=" + re.escape(case) + r"(?:\s|$)",
                             pass_lines[0]) is not None
                and re.search(r"Fatal:", log, re.I) is None)
    # This is a diagnostic witness, never "any nonzero exit is a pass".
    # The one exact diagnostic must belong to the one native Fatal block.
    # Exit zero after $fatal is explicitly supported; launcher crashes are not.
    if code not in (0, 1) or pass_lines or expected_fatal not in WITNESS_DIAGNOSTICS:
        return False
    lines = log.splitlines()
    fatals = [i for i, line in enumerate(lines) if re.match(r"^\s*Fatal:", line, re.I)]
    token = r"\b" + re.escape(expected_fatal) + r"\b"
    if (len(fatals) != 1 or len(re.findall(r"Fatal:", log, re.I)) != 1
            or len(re.findall(token, log)) != 1):
        return False
    i = fatals[0]
    diagnostic = WITNESS_DIAGNOSTICS[expected_fatal]
    return any(re.search(diagnostic, line) is not None for line in lines[i:i + 2])


def command(value: str, label: str, prepare_only: bool) -> list[str]:
    words = shlex.split(value)
    if not words:
        raise ValueError(label + ": empty command")
    words[0] = os.path.expanduser(words[0])
    found = shutil.which(words[0])
    if found:
        # Retain argv[0] identity for dispatching host wrappers: no resolve().
        words[0] = os.path.abspath(found)
    elif not prepare_only:
        raise UnavailableTool(label + " executable unavailable: " + words[0])
    return words


def execute(argv: list[str], log: Path, work: Path) -> int:
    with log.open("x", encoding="utf-8") as stream:
        return subprocess.run(argv, cwd=work, stdout=stream, stderr=subprocess.STDOUT,
                              check=False).returncode


def load_builder():
    spec = importlib.util.spec_from_file_location("d2h_composition_build", HERE / "build.py")
    if spec is None or spec.loader is None:
        raise ValueError("missing composition build.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--suite", choices=tuple(SUITES) + ("all",), default="all")
    for name in PRIVATE_PINS:
        p.add_argument("--" + name, type=Path, required=True, help="actual PRIVATE " + name + " source")
    p.add_argument("--quartus-simlib", type=Path, required=True,
                   help="compatible 23.1 standard eda/sim_lib with altera_mf.v and 220model.v")
    p.add_argument("--vcs", default=os.environ.get("VCS", "vcs"))
    p.add_argument("--runner", default=os.environ.get("VCS_RUN", "vcs-run"),
                   help="VCS simulation launcher; --runner= executes the compiled simv directly")
    p.add_argument("--vcs-arg", action="append", default=[])
    p.add_argument("--sim-arg", action="append", default=[])
    p.add_argument("--seed", type=int, action="append", help="distinct nonzero uint32; default 1,17,73")
    p.add_argument("--build-dir", type=Path, required=True, help="NEW private output directory")
    p.add_argument("--prepare-only", action="store_true")
    p.add_argument("--check-lean", action="store_true", help="also check Contract.lean with Lean 4.19.0")
    p.add_argument("--lean", default=os.environ.get("LEAN", "lean"))
    a = p.parse_args()
    seeds = a.seed or [1, 17, 73]
    if len(set(seeds)) != len(seeds) or any(not 0 < seed < 2**32 for seed in seeds):
        raise ValueError("--seed values must be distinct nonzero uint32")
    if any(arg.startswith(("+CASE=", "+SEED=", "+ntb_random_seed=")) for arg in a.sim_arg):
        raise ValueError("CASE and SEED are chosen only through --suite and --seed")
    # These are tool options, not shell programs; subprocess never uses a shell.
    compiler = command(a.vcs, "VCS", a.prepare_only)
    runner = command(a.runner, "VCS runner", a.prepare_only) if a.runner else []
    lean = command(a.lean, "Lean 4.19.0", a.prepare_only) if a.check_lean else []
    inputs: dict[str, str] = {}
    original: dict[str, bytes] = {}
    owned: dict[str, bytes] = {}
    for name, pins in PRIVATE_PINS.items():
        path, raw = read_source(getattr(a, name), name, pins)
        original[name] = raw
        inputs[str(path)] = sha(raw)
    for relative, pin in OWNED_PINS.items():
        path, raw = read_source(REPO / relative, relative, (pin,))
        owned[relative] = raw
        inputs[str(path)] = sha(raw)
    added: dict[str, bytes] = {}
    for name in INCLUDES + ("build.py", "run.py", "Contract.lean"):
        path, raw = read_source(HERE / name, name)
        added[name] = raw
        inputs[str(path)] = sha(raw)
    models: dict[str, bytes] = {}
    for name in ("altera_mf.v", "220model.v"):
        path, raw = read_source(a.quartus_simlib / name, name)
        models[name] = raw
        inputs[str(path)] = sha(raw)

    # No predecessor transformer is executed before its exact own bytes and
    # transitive imports are verified. The original files are never modified.
    sys.path.insert(0, str(REPO / "experiments/dma-status-v3/tools"))
    from build_payload_unaligned import transform as transform_payload
    from build_readmem_count import transform as transform_producer
    from build_packetizer import transform_aligner, transform_tlpgen
    builder = load_builder()
    producer = original["producer"]
    if sha(producer) == PRODUCER_ORIGINAL:
        producer = transform_producer(producer)
    if sha(producer) != PRODUCER_CORRECTED:
        raise ValueError("corrected 19-bit producer SHA256 mismatch")
    sources = {
        "dma_payload_unaligned_candidate.sv": transform_payload(original["payload"]).encode("utf-8"),
        "arria10_dma_ddr_mux.sv": original["mux"],
        "altpcieav_dma_wr_readmem_2.sv": producer,
        "altpcie_fifo.sv": original["fifo"],
        "altpcieav_dma_wr_2.sv": original["wrapper"],
        "altpcieav_dma_wr_wdalign_2.sv": transform_aligner(original["aligner"]),
        "altpcieav_dma_wr_tlpgen_2.sv": transform_tlpgen(original["tlpgen"]),
        "dma_memory_path_unaligned_candidate.sv":
            owned["experiments/dma-status-v3/rtl/dma_memory_path_unaligned_candidate.sv"],
        TOP + ".sv": builder.build_bench(
            owned["experiments/dma-status-v3/tests/native_d2h_packetizer_tb.sv"]),
        **models,
    }
    selected = list(SUITES) if a.suite == "all" else [a.suite]
    variants = dict.fromkeys(SUITES[suite][0] for suite in selected)
    generated: dict[str, dict[str, bytes]] = {}
    for mode in variants:
        is_original = mode == "original"
        generated[mode] = {
            "controller.sv": builder.build_controller(original["controller"], original=is_original),
            "controller_tx_v4.svh": builder.build_tx(
                owned["experiments/dma-fetch-v4/rtl/controller_tx_v4.svh"], original=is_original),
        }
    if any(not isinstance(raw, bytes) for raw in sources.values()):
        raise TypeError("RTL transformations must return exact bytes")
    # All source/pin/transform validation precedes the first new directory.
    build = a.build_dir.expanduser().resolve()
    build.mkdir(parents=True, exist_ok=False, mode=0o700)
    for name, raw in {**sources, **{name: added[name] for name in INCLUDES}}.items():
        (build / name).write_bytes(raw)
    (build / "Contract.lean").write_bytes(added["Contract.lean"])
    result = {
        "base_commit": BASE_COMMIT,
        "prepared_only": a.prepare_only,
        "scope": "isolated DCS/DTS controller through native packet FIFO and accepted DCM/MSI sink writes",
        "production_driver_contract_valid": False,
        "physical_acceptance": False,
        "inputs": inputs,
        "generated": {name: sha(raw) for name, raw in sources.items()},
        "compiles": [], "runs": [],
        "lean": {"requested": a.check_lean, "attempted": False},
    }
    report = build / "result.json"

    def save() -> None:
        temporary = report.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        temporary.replace(report)

    for mode, files in generated.items():
        work = build / mode
        work.mkdir(mode=0o700)
        for name, raw in files.items():
            (work / name).write_bytes(raw)
        binary = work / "simv"
        argv = compiler + ["-full64", "-sverilog", "-timescale=1ns/1ps",
                           "+define+ARRIA10_ASSERTIONS", "+incdir+" + str(work),
                           "+incdir+" + str(build), "-top", TOP, "-o", str(binary)]
        if mode == "original":
            argv.append("+define+D2H_ORIGINAL_CONTROLLER")
        argv += a.vcs_arg + [str(build / name) for name in sources] + [str(work / "controller.sv")]
        entry = {"variant": mode, "argv": argv, "attempted": False,
                 "generated": {name: sha(raw) for name, raw in files.items()}}
        result["compiles"].append(entry)
        save()
        if not a.prepare_only:
            entry["attempted"] = True
            save()
            log = work / "compile.log"
            code = execute(argv, log, work)
            passed = passed_compile(code, log.read_text(errors="replace"), binary.is_file())
            entry.update(returncode=code, passed=passed)
            save()
            if not passed:
                print(f"FAIL compile: {log}", file=sys.stderr)
                return 1
    for suite in selected:
        mode, case, expected = SUITES[suite]
        work = build / suite
        work.mkdir(mode=0o700)
        for seed in seeds:
            argv = runner + [str(build / mode / "simv"), "-no_save",
                             f"+ntb_random_seed={seed}", f"+SEED={seed}", "+CASE=" + case] + a.sim_arg
            entry = {"suite": suite, "seed": seed, "argv": argv, "attempted": False,
                     "expected_fatal": expected}
            result["runs"].append(entry)
            save()
            if a.prepare_only:
                continue
            entry["attempted"] = True
            save()
            log = work / f"seed_{seed}.log"
            code = execute(argv, log, work)
            passed = passed_run(code, log.read_text(errors="replace"), case, expected)
            entry.update(returncode=code, passed=passed)
            save()
            print(f"{'PASS' if passed else 'FAIL'} {suite} seed={seed}: {log}")
            if not passed:
                return 1
    if a.check_lean:
        version_argv = lean + ["--version"]
        proof_argv = lean + [str(build / "Contract.lean")]
        result["lean"].update(version_argv=version_argv, argv=proof_argv)
        save()
        if not a.prepare_only:
            result["lean"]["attempted"] = True
            save()
            code = execute(version_argv, build / "lean-version.log", build)
            version = (build / "lean-version.log").read_text(errors="replace")
            if code or re.search(r"\bversion 4\.19\.0\b", version) is None:
                result["lean"].update(version_returncode=code, passed=False)
                save()
                raise ValueError("Lean must identify itself as version 4.19.0; see lean-version.log")
            code = execute(proof_argv, build / "lean.log", build)
            log = (build / "lean.log").read_text(errors="replace")
            passed = code == 0 and re.search(r"\berror\b|\bsorry\b|\badmit\b", log, re.I) is None
            result["lean"].update(returncode=code, passed=passed)
            save()
            if not passed:
                print(f"FAIL Lean: {build / 'lean.log'}", file=sys.stderr)
                return 1
    result["originals_unchanged"] = all(sha(Path(path).read_bytes()) == pin for path, pin in inputs.items())
    save()
    if not result["originals_unchanged"]:
        raise ValueError("an input changed during this run")
    print(("PREPARED ONLY; no VCS or Lean execution: " if a.prepare_only else
           "Requested isolated VCS cases completed; see explicit Lean status: ") + str(report))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except UnavailableTool as error:
        print(f"UNAVAILABLE: {error}", file=sys.stderr)
        raise SystemExit(77)
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        print(f"INPUT/EXECUTION ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
