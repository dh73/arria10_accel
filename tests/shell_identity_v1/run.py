"""Run installed VCS, the actual C++ decoder, and installed Lean 4.19.0."""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess

BAD = re.compile(r"Fatal:|Error!|Error:|Error-\[")
ROOT = Path(__file__).resolve().parents[2]


def acceptable(text, marker=None):
    return not BAD.search(text) and (marker is None or text.splitlines().count(marker) == 1)


def run(argv, directory, log, marker=None):
    print("+ " + " ".join(str(a) for a in argv), flush=True)
    result = subprocess.run([str(a) for a in argv], cwd=directory,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")
    log.write_text(result.stdout, encoding="utf-8")
    if result.returncode != 0 or not acceptable(result.stdout, marker):
        raise RuntimeError("failed command or missing/invalid marker: " + str(log))
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host-test", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--vcs", default=os.environ.get("VCS_BIN", "vcs"))
    parser.add_argument("--runner", default="", help="optional simulation launcher command")
    parser.add_argument("--lean", type=Path, required=True,
                        help="absolute path to an already installed Lean 4.19.0 binary")
    parser.add_argument("--mmio", action="store_true", help="Exercise the bus frontend before host transcript decoding")
    args = parser.parse_args()
    if not args.lean.is_absolute() or not args.lean.is_file() or args.lean.resolve().name == "elan":
        raise ValueError("--lean must be an installed Lean binary, not an installer/shim")
    lean = args.lean.resolve()
    host = args.host_test.resolve(strict=True)
    work = args.work.absolute()
    work.mkdir(parents=True, exist_ok=False)
    marker = "A10_IDENTITY_RTL_PASS"
    for token in ("Fatal:", "Error!", "Error:", "Error-["):
        if acceptable(token + " injected\n" + marker + "\n", marker):
            raise RuntimeError("fatal scanner accepted a negative control")
    if acceptable("no positive marker\n", marker) or acceptable(marker + "\n" + marker, marker):
        raise RuntimeError("positive marker scanner is permissive")
    version = run([lean, "--version"], work, work / "lean-version.log")
    if not re.search(r"\bversion 4\.19\.0(?:\W|$)", version):
        raise RuntimeError("Lean 4.19.0 is required")
    run([host], work, work / "host.log", "A10_IDENTITY_HOST_PASS")
    run([host, "--emit-rtl", work / "shell_identity_params.svh"],
        work, work / "params.log")
    simv = work / "simv"
    run([args.vcs, "-full64", "-sverilog", "-timescale=1ns/1ps",
         *(["+define+IDENTITY_MMIO", ROOT / "rtl/shell_identity_mmio.sv"] if args.mmio else []),
         "+define+PLATFORM_SUPERVISOR_ASSERTIONS", "+incdir+" + str(work),
         "-top", "tb", ROOT / "rtl/platform_supervisor.sv",
         ROOT / "rtl/shell_identity_v1.sv", ROOT / "tests/shell_identity_v1/tb.sv",
         "-o", simv], work, work / "compile.log")
    dump = work / "rtl-reads.txt"
    run([*shlex.split(args.runner), simv, "-no_save", "+DUMP=" + str(dump)], work, work / "rtl.log", marker)
    run([host, "--from-rtl", dump], work, work / "rtl-host.log",
        "A10_IDENTITY_RTL_HOST_PASS")
    run([lean, ROOT / "proof/shell_identity_v1/Main.lean"], work, work / "lean.log")
    print("A10_IDENTITY_SUITE_PASS")


if __name__ == "__main__":
    main()
