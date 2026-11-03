#!/usr/bin/env python3
"""Run the Lean 4.19 model and native VCS tests; never programs a device."""
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def simulation_pass(code, text, positive):
    if positive:
        return (code == 0 and "C126_RESET_RELEASE_RTL_PASS" in text and
                not re.search(r"Fatal:|Error:|Error-\[", text))
    # This runtime returns zero after $fatal. Require the exact negative-control
    # diagnostic and time-zero DUT failure; exit status alone is insufficient.
    return (code in (0, 1) and text.count("Fatal:") == 1 and
            text.count("C126_RELEASE_HOLD_REF_CYCLES_REQUIRED") == 1 and
            re.search(r"Fatal: [^\n]*tb_c126_reset_release_invalid\.dut: at time 0 ps", text) is not None and
            "C126_INVALID_PARAMETER_NOT_REJECTED" not in text and
            not re.search(r"Error:|Error-\[|Segmentation|core dumped", text))


def run(argv, out, name, success=True):
    print(shlex.join(map(str, argv)), flush=True)
    try:
        result = subprocess.run(list(map(str, argv)), cwd=out, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as error:
        (out / name).write_text(str(error) + "\n", encoding="utf-8")
        raise RuntimeError(f"Tool unavailable; inspect {out / name}") from error
    (out / name).write_text(result.stdout, encoding="utf-8")
    if success is not None and success != (result.returncode == 0):
        raise RuntimeError(f"Unexpected exit={result.returncode}; inspect {out / name}")
    return (result.returncode, result.stdout) if success is None else result.stdout


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--vcs", default="vcs")
    p.add_argument("--lean", default="lean")
    p.add_argument("--only", choices=("all", "lean", "vcs"), default="all")
    args = p.parse_args()
    out = args.work.resolve()
    out.mkdir(parents=True, exist_ok=False)
    # Versions are retained verbatim; the proof is specifically pinned to 4.19.
    if args.only in ("all", "lean"):
        version = run([args.lean, "--version"], out, "lean-version.log")
        if not re.search(r"\bversion 4\.19\.0\b", version):
            raise RuntimeError("Lean 4.19.0 is required")
        proof = run([args.lean, HERE / "ReleaseModel.lean"], out, "lean.log")
        if "sorryAx" in proof:
            raise RuntimeError("Lean model contains an unproved obligation")
        print("C126_LEAN_RELEASE_MODEL_CHECKED: deterministic model only")
    if args.only == "lean":
        return
    run([args.vcs, "-ID"], out, "vcs-version.log")
    for top, label, expected in (
        ("tb_c126_reset_release", "positive", True),
        ("tb_c126_reset_release_invalid", "invalid", False),
    ):
        simv = out / ("simv-" + label)
        run([args.vcs, "-full64", "-sverilog", "-timescale=1ns/1ps", "-top", top,
             HERE / "c126_reset_release.sv", HERE / "tb_c126_reset_release.sv",
             "-Mdir=" + str(out / ("csrc-" + label)), "-o", simv],
            out, label + "-compile.log")
        code, log = run([simv], out, label + "-simulate.log", None)
        if not simulation_pass(code, log, expected):
            raise RuntimeError(f"Missing or incorrect test result in {label}")
    print("C126_VCS_RESET_RELEASE_RTL_PASS: simulation only; hard-IP closure remains open")
    if args.only == "all":
        print("C126_RESET_RELEASE_CHECKS_PASS: digital model and VCS only")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        sys.exit(str(error))
