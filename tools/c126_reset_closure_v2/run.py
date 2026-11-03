#!/usr/bin/env python3
"""Isolate C126 and run native retained-DB diagnosis / partial SDC comparison."""
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

PACKET_SHA = "0d9b270f861915162ec4443cecbd3180c565738878638ab60d947a017d7ebad2"
PREFIX = "qualification/c126-review-preflight-v1/snapshot/"
IP = "ip/ed_synth/ed_synth_emif/altera_emif_arch_nf_191/synth/"
SOFT = "ed_synth_inst|emif|emif|arch|arch_inst|cal_counter_inst|non_hps.inst_sync_reset_n|din_s1"
PORTS = ["emif_status_local_cal_fail[0]", "emif_status_local_cal_success[0]",
         "emif_tg_0_traffic_gen_fail[0]", "emif_tg_0_traffic_gen_pass[0]",
         "emif_tg_0_traffic_gen_timeout[0]"]
HERE = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def source_packet(path):
    require(digest(path) == PACKET_SHA, "Source packet SHA-256 differs from the supplied C126 packet")
    text = path.read_text(encoding="utf-8")
    starts = list(re.finditer(r"^FILE ([^\n]+)\n", text, re.M))
    stop = text.index("\nQSF SELECTED ASSIGNMENTS")
    files = {}
    for i, match in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else stop
        require(match[1] not in files, "Duplicate source packet member")
        files[match[1]] = text[match.end():end].rstrip("\r\n")
    sources = {name[len(PREFIX):]: body for name, body in files.items() if name.startswith(PREFIX)}
    require(len(sources) == 6, "Expected the six supplied source/SDC files")
    assessment = json.loads(files["qualification/c126-reset-audit-v1/assessment.json"])
    endpoints = assessment["reset_endpoints"]
    require(len(endpoints) == len({r["to"] for r in endpoints}) == 22,
            "Expected all 22 distinct reset endpoints")
    selected = text[stop:].splitlines()[1:]
    selected = [s.strip() for s in selected if s.startswith("set_")]
    return sources, assessment, selected


def verify_sources(root, sources):
    result = {}
    for relative, expected in sources.items():
        path = root / relative
        require(path.is_relative_to(root), "Unsafe packet member")
        require(path.read_text(encoding="utf-8").rstrip("\r\n") == expected,
                f"Baseline differs from packet: {relative}")
        result[relative] = digest(path)
    return result


def stage(args):
    root, work = args.baseline.resolve(strict=True), args.work.resolve()
    require(not work.exists(), f"Refusing to overwrite {work}")
    require(not work.is_relative_to(root) and not root.is_relative_to(work),
            "Baseline and work trees must be disjoint")
    for name in (args.project, args.revision):
        require(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", name), "Use project/revision basenames")
    require((root / (args.project + ".qpf")).is_file(), "Project .qpf is missing")
    sources, assessment, selected = source_packet(args.packet.resolve(strict=True))
    hashes = verify_sources(root, sources)
    qsf = root / (args.revision + ".qsf")
    actual = {line.strip() for line in qsf.read_text().splitlines()}
    require(all(line in actual for line in selected), "Selected C126 QSF assignments differ")
    # No symlinks/hard links back to the original. A self-contained project
    # tree is required; the caller includes its db/qdb/output_files contents.
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"Stage a self-contained tree first; symlink: {path}")
    work.mkdir()
    shutil.copytree(root, work / "project", copy_function=shutil.copy2)
    verify_sources(work / "project", sources)
    shutil.copytree(HERE, work / "package", ignore=shutil.ignore_patterns("__pycache__"))
    hashes[args.revision + ".qsf"] = digest(qsf)
    state = {"packet_sha256": PACKET_SHA, "baseline": str(root), "project": args.project,
             "revision": args.revision, "sources": hashes, "assessment": assessment}
    (work / "c126.json").write_text(json.dumps(state, indent=2) + "\n")
    print(f"Isolated retained project: {work / 'project'}")


def load_work(work):
    work = work.resolve(strict=True)
    state = json.loads((work / "c126.json").read_text())
    require(state["packet_sha256"] == PACKET_SHA, "Wrong C126 stage")
    for relative, expected in state["sources"].items():
        require(digest(work / "project" / relative) == expected,
                f"Staged source changed: {relative}")
    return work, state


def tcl_word(value):
    # A double-quoted Tcl word, not shell quoting. Suppress all substitutions.
    value = str(value)
    mapping = {"\\": "\\\\", '"': '\\"', "$": "\\$", "[": "\\[", "]": "\\]",
               "\n": "\\n", "\r": "\\r", "\t": "\\t"}
    return '"' + "".join(mapping.get(c, c) for c in value) + '"'


def invoke(command, cwd, log):
    print(shlex.join(map(str, command)), flush=True)
    with log.open("x") as stream:
        completed = subprocess.run(list(map(str, command)), cwd=cwd, stdout=stream,
                                   stderr=subprocess.STDOUT, check=False)
    print(f"Native exit={completed.returncode}; log={log}", flush=True)
    require(completed.returncode == 0, f"Native invocation failed; inspect {log}")


def analyze(args):
    work, state = load_work(args.work)
    quartus = args.quartus_bin.resolve(strict=True) / "quartus_sta"
    version = subprocess.run([str(quartus), "--version"], text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True).stdout
    require(re.search(r"\b26\.1(?:\.|\s)", version), "This candidate requires native Quartus 26.1")
    require(args.mode == "candidate" or not args.status_observation_only,
            "The observation-only option applies only to candidate mode")
    label = args.mode + ("-status" if args.status_observation_only else "")
    out = work / "runs" / label
    out.mkdir(parents=True, exist_ok=False)
    (out / "version.txt").write_text(version)
    values = {"root": work / "project", "project": state["project"], "revision": state["revision"],
              "out": out, "package": work / "package", "mode": args.mode,
              "baseline": state["baseline"],
              "soft": SOFT, "packet_verified": 1,
              "status_observation_only": int(args.status_observation_only)}
    config = "namespace eval ::c126 {}\n"
    config += "".join(f"set ::c126::{key} {tcl_word(value)}\n" for key, value in values.items())
    endpoints = state["assessment"]["reset_endpoints"]
    config += "set ::c126::reset_endpoints [list " + " ".join(tcl_word(e["to"]) for e in endpoints) + "]\n"
    config += "set ::c126::expected_clock [dict create " + " ".join(
        tcl_word(v) for e in endpoints for v in (e["to"], e["clock"])) + "]\n"
    config += "set ::c126::status_ports [list " + " ".join(map(tcl_word, PORTS)) + "]\n"
    config_path = out / "config.tcl"
    config_path.write_text(config)
    invoke([quartus, "-t", work / "package/native.tcl", config_path], work / "project", out / "native.log")
    # Imported only after native success; missing reports cannot become a pass.
    sys.path.insert(0, str(work / "package"))
    from assess import assess
    result = assess(out, state["assessment"], args.mode, args.status_observation_only)
    (out / "assessment.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    if args.require_hard_reset_closure:
        require(result["closure_pass"],
                "C126 hard-reset closure BLOCKED: exact ES3/26.1 release/clock/pulse-width "
                "contract for the 21 hard-IP endpoints is unresolved; see README.md")


def vcs(args):
    work, _ = load_work(args.work)
    out = work / "runs" / "vcs-soft"
    out.mkdir(parents=True, exist_ok=False)
    vendor = work / "project" / IP
    executable = out / "simv"
    invoke([args.vcs, "-full64", "-sverilog", "-top", "tb_cal_counter",
            vendor / "altera_std_synchronizer_nocut.v",
            vendor / "altera_emif_arch_nf_cal_counter.sv",
            work / "package/tb_cal_counter.sv", "-o", executable], out, out / "compile.log")
    invoke([executable], out, out / "simulate.log")
    require("C126_SOFT_CAL_COUNTER_RTL_PASS" in (out / "simulate.log").read_text(),
            "VCS exited without the fixture PASS tag")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("stage")
    s.add_argument("--baseline", type=Path, required=True)
    s.add_argument("--work", type=Path, required=True)
    s.add_argument("--packet", type=Path, required=True)
    s.add_argument("--project", required=True)
    s.add_argument("--revision", required=True)
    s.set_defaults(function=stage)
    a = sub.add_parser("sta")
    a.add_argument("--work", type=Path, required=True)
    a.add_argument("--mode", choices=("diagnose", "candidate"), default="diagnose")
    a.add_argument("--status-observation-only", action="store_true",
                   help="Declare the five status ports untimed indication outputs, without claiming board verification")
    a.add_argument("--require-hard-reset-closure", action="store_true",
                   help="Return nonzero after writing the assessment while hard-IP contracts remain open")
    a.add_argument("--quartus-bin", type=Path,
                   default=Path("/home/diego1/work/tools/syn/altera_pro/26.1/quartus/bin"))
    a.set_defaults(function=analyze)
    v = sub.add_parser("vcs")
    v.add_argument("--work", type=Path, required=True)
    v.add_argument("--vcs", default="vcs")
    v.set_defaults(function=vcs)
    args = parser.parse_args()
    args.function(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
