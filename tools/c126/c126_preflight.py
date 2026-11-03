#!/usr/bin/env python3
"""Read-only preflight and isolated-snapshot build wrapper for the C126 ES3 EMIF example.

The tool never edits the supplied source tree.  It creates a new output directory,
copies regular source files into output/snapshot, emits a machine-readable report,
and only invokes Quartus when the explicit ``build`` subcommand is selected.
It does not program the FPGA, bind a driver, change PCI configuration, copy a
license, or claim that generated constraints are electrically qualified.

Python 3.10+; standard library only.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as _dt
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Iterator, Mapping, Sequence

TOOL_VERSION = "1.1"
DEFAULT_DEVICE = "10AX115S3F45E2SGE3"
DEFAULT_TOP = "ed_synth_top"
DEFAULT_PROJECT = "ed_synth"

# Fresh identities supplied with the C126 handoff.  A mismatch means that the
# input is not byte-identical to that captured source; it does not by itself say
# whether a changed source is correct.
KNOWN_C126_HASHES: Mapping[str, str] = {
    "ed_synth.qsf": "d5e125109c6e4e4f0109e8d3370c9bc73108e4877a2589d84d96fca4ea84c397",
    "ed_synth.qpf": "ae08b6cec1c991a7ede420bb9b7cfb105aac03bb78aadf553b943d8020a85bc0",
    "ed_synth.qsys": "e3d1109a9fd32bba09122c1d76bb08cc5ff295d754528657c90940c0661886c9",
    "ed_synth_top.sv": "3a9daeb09aaaa9615fe18e38a25c0951112940af5d32d6ca9c8f5daa08920b79",
    "jtag_example.sdc": "43e7df29039718a133b5c8cd3dbd748cf9340786baa60e3ba865566f3b4e7c19",
    "ip/ed_synth/ed_synth_emif.ip": "d9f4f8f02629c80576d21ce3e344dbf83a4ea5c14986242577d5df9ab1bea11b",
}

GENERATED_OUTPUT_DIRS = {
    "db",
    "incremental_db",
    "output_files",
    "greybox_tmp",
    ".qsys_edit",
}

BUILD_REFERENCE_ASSIGNMENTS = {
    "QSYS_FILE",
    "IP_FILE",
    "SDC_FILE",
    "SYSTEMVERILOG_FILE",
    "VERILOG_FILE",
    "VHDL_FILE",
    "QIP_FILE",
    "MIF_FILE",
    "HEX_FILE",
    "SOURCE_TCL_SCRIPT_FILE",
}

EXPECTED_INDEXED_PORTS: Mapping[str, frozenset[int]] = {
    "emif_mem_mem_a": frozenset(range(17)),
    "emif_mem_mem_act_n": frozenset({0}),
    "emif_mem_mem_alert_n": frozenset({0}),
    "emif_mem_mem_ba": frozenset(range(2)),
    "emif_mem_mem_bg": frozenset({0}),
    "emif_mem_mem_ck": frozenset({0}),
    "emif_mem_mem_ck_n": frozenset({0}),
    "emif_mem_mem_cke": frozenset({0}),
    "emif_mem_mem_cs_n": frozenset({0}),
    "emif_mem_mem_dbi_n": frozenset(range(9)),
    "emif_mem_mem_dq": frozenset(range(72)),
    "emif_mem_mem_dqs": frozenset(range(9)),
    "emif_mem_mem_dqs_n": frozenset(range(9)),
    "emif_mem_mem_odt": frozenset({0}),
    "emif_mem_mem_par": frozenset({0}),
    "emif_mem_mem_reset_n": frozenset({0}),
    "emif_oct_oct_rzqin": frozenset({0}),
    "emif_pll_ref_clk_clk": frozenset({0}),
    "emif_status_local_cal_fail": frozenset({0}),
    "emif_status_local_cal_success": frozenset({0}),
    "emif_tg_0_traffic_gen_fail": frozenset({0}),
    "emif_tg_0_traffic_gen_pass": frozenset({0}),
    "emif_tg_0_traffic_gen_timeout": frozenset({0}),
    "global_reset_reset_n": frozenset({0}),
}

EXPECTED_KEY_PINS: Mapping[str, str] = {
    "emif_mem_mem_ck[0]": "PIN_R30",
    "emif_mem_mem_ck_n[0]": "PIN_R31",
    "emif_oct_oct_rzqin[0]": "PIN_J34",
    "emif_pll_ref_clk_clk[0]": "PIN_F34",
    "emif_status_local_cal_fail[0]": "PIN_M23",
    "emif_status_local_cal_success[0]": "PIN_D18",
    "emif_tg_0_traffic_gen_fail[0]": "PIN_L27",
    "emif_tg_0_traffic_gen_pass[0]": "PIN_L28",
    "emif_tg_0_traffic_gen_timeout[0]": "PIN_L23",
    "global_reset_reset_n[0]": "PIN_U11",
}

STATUS_PORTS = (
    "emif_status_local_cal_fail",
    "emif_status_local_cal_success",
    "emif_tg_0_traffic_gen_fail",
    "emif_tg_0_traffic_gen_pass",
    "emif_tg_0_traffic_gen_timeout",
)


class PreflightError(RuntimeError):
    """A deterministic local/preflight error, not a Quartus or hardware result."""


@dataclasses.dataclass(frozen=True)
class Issue:
    severity: str
    code: str
    message: str
    path: str | None = None
    line: int | None = None

    def as_dict(self) -> dict[str, object]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class GlobalAssignment:
    name: str
    value: str
    line: int


@dataclasses.dataclass(frozen=True)
class LocationAssignment:
    pin: str
    port: str
    line: int


@dataclasses.dataclass
class QsfModel:
    globals: list[GlobalAssignment]
    locations: list[LocationAssignment]
    instance_io_standards: list[tuple[str, str, int]]
    external_path_hints: list[tuple[str, str, int]]

    def global_values(self, name: str) -> list[str]:
        return [a.value for a in self.globals if a.name == name]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _is_relative_to(path: Path, base: Path) -> bool:
    try:
        path.relative_to(base)
        return True
    except ValueError:
        return False


def require_disjoint_source_output(source: Path, output: Path) -> tuple[Path, Path]:
    source_r = source.resolve(strict=True)
    output_r = output.resolve(strict=False)
    if not source_r.is_dir():
        raise PreflightError(f"source is not a directory: {source_r}")
    if output_r == source_r or _is_relative_to(output_r, source_r):
        raise PreflightError("output must not be the source directory or a child of it")
    if _is_relative_to(source_r, output_r):
        raise PreflightError("source must not be inside the requested output directory")
    if output.exists():
        raise PreflightError(f"output already exists; refusing to overwrite: {output}")
    return source_r, output_r


def _logical_lines(text: str) -> Iterator[tuple[int, str]]:
    start = 1
    acc = ""
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.rstrip()
        if not acc:
            start = number
        if line.endswith("\\"):
            acc += line[:-1] + " "
            continue
        acc += line
        yield start, acc
        acc = ""
    if acc:
        yield start, acc


def tcl_words(line: str) -> list[str]:
    """Tokenize the small Tcl command subset used by QSF files.

    It understands double quotes, balanced braces, backslash escaping and
    comments beginning with an unquoted '#'.  It intentionally does not execute
    Tcl substitutions.
    """

    words: list[str] = []
    token: list[str] = []
    quote = False
    brace_depth = 0
    escape = False

    def finish() -> None:
        if token:
            words.append("".join(token))
            token.clear()

    i = 0
    while i < len(line):
        ch = line[i]
        if escape:
            token.append(ch)
            escape = False
        elif ch == "\\":
            escape = True
        elif quote:
            if ch == '"':
                quote = False
            else:
                token.append(ch)
        elif brace_depth:
            if ch == "{":
                brace_depth += 1
                if brace_depth > 1:
                    token.append(ch)
            elif ch == "}":
                brace_depth -= 1
                if brace_depth:
                    token.append(ch)
            else:
                token.append(ch)
        elif ch == '"':
            quote = True
        elif ch == "{":
            brace_depth = 1
        elif ch == "#":
            break
        elif ch.isspace():
            finish()
        else:
            token.append(ch)
        i += 1
    if escape:
        token.append("\\")
    if quote or brace_depth:
        raise PreflightError(f"unterminated QSF quote/brace in line: {line!r}")
    finish()
    return words


def _option_value(words: Sequence[str], option: str) -> str | None:
    try:
        index = words.index(option)
    except ValueError:
        return None
    if index + 1 >= len(words):
        return None
    return words[index + 1]


def parse_qsf(path: Path) -> QsfModel:
    text = path.read_text(encoding="utf-8", errors="strict")
    globals_: list[GlobalAssignment] = []
    locations: list[LocationAssignment] = []
    io_standards: list[tuple[str, str, int]] = []
    external_hints: list[tuple[str, str, int]] = []

    for line_no, line in _logical_lines(text):
        words = tcl_words(line)
        if not words:
            continue
        command = words[0]
        if command == "set_global_assignment":
            name = _option_value(words, "-name")
            if name is None:
                continue
            name_index = words.index("-name")
            if name_index + 2 >= len(words):
                continue
            value = words[name_index + 2]
            globals_.append(GlobalAssignment(name=name, value=value, line=line_no))
            if ("/" in value or "\\" in value) and value.startswith(".."):
                external_hints.append((name, value, line_no))
        elif command == "set_location_assignment":
            port = _option_value(words, "-to")
            if len(words) >= 2 and port is not None:
                locations.append(LocationAssignment(pin=words[1], port=port, line=line_no))
        elif command == "set_instance_assignment":
            name = _option_value(words, "-name")
            target = _option_value(words, "-to")
            if name == "IO_STANDARD" and target is not None:
                name_index = words.index("-name")
                if name_index + 2 < len(words):
                    io_standards.append((target, words[name_index + 2], line_no))

    return QsfModel(
        globals=globals_,
        locations=locations,
        instance_io_standards=io_standards,
        external_path_hints=external_hints,
    )


def find_project_files(source: Path, project: str) -> tuple[Path, Path]:
    if re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", project) is None:
        raise PreflightError("project must be a simple local project name, not a path")
    qsf = source / f"{project}.qsf"
    qpf = source / f"{project}.qpf"
    if not qsf.is_file():
        raise PreflightError(f"missing project QSF: {qsf}")
    if not qpf.is_file():
        raise PreflightError(f"missing project QPF: {qpf}")
    return qsf, qpf


def scan_symlinks(source: Path) -> list[Path]:
    found: list[Path] = []
    for root, dirnames, filenames in os.walk(source, followlinks=False):
        root_p = Path(root)
        for name in [*dirnames, *filenames]:
            candidate = root_p / name
            if candidate.is_symlink():
                found.append(candidate)
    return sorted(found)


def _safe_reference(source: Path, raw: str) -> tuple[Path | None, str | None]:
    # Environment-variable and Tcl-substitution paths cannot be resolved safely
    # by this non-executing parser and therefore require manual inspection.
    if "$" in raw or "[" in raw or "]" in raw:
        return None, "dynamic"
    raw_normalized = raw.replace("\\", "/")
    candidate = (source / raw_normalized).resolve(strict=False)
    if not _is_relative_to(candidate, source):
        return candidate, "escape"
    return candidate, None


def _port_base_and_index(port: str) -> tuple[str, int | None]:
    match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_$]*)(?:\[(\d+)\])?", port)
    if not match:
        return port, None
    return match.group(1), int(match.group(2)) if match.group(2) is not None else None


def parse_top_port_names(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8", errors="strict")
    # Remove comments before extracting ANSI-style port declarations.
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    text = re.sub(r"//.*", " ", text)
    names = set(
        re.findall(
            r"\b(?:input|output|inout)\b(?:\s+(?:wire|logic|reg|signed|unsigned))*"
            r"(?:\s*\[[^\]]+\])?\s+([A-Za-z_][A-Za-z0-9_$]*)",
            text,
        )
    )
    return names


def _active_low_status_assignments(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8", errors="strict")
    return set(
        re.findall(
            r"\bassign\s+([A-Za-z_][A-Za-z0-9_$]*)\s*=\s*~\s*[A-Za-z_][A-Za-z0-9_$]*\s*;",
            text,
        )
    )


def manifest(source: Path) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if any(part in GENERATED_OUTPUT_DIRS for part in relative.parts):
            continue
        if path.is_symlink():
            raise PreflightError(f"source contains symlink, refusing snapshot: {relative}")
        if path.is_file():
            st = path.stat()
            entries.append(
                {
                    "path": relative.as_posix(),
                    "bytes": st.st_size,
                    "sha256": sha256_file(path),
                    "mode": stat.S_IMODE(st.st_mode),
                }
            )
    return entries


def manifest_digest(entries: Sequence[Mapping[str, object]]) -> str:
    encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def copy_snapshot(source: Path, destination: Path) -> None:
    def ignore(directory: str, names: list[str]) -> set[str]:
        del directory
        return {name for name in names if name in GENERATED_OUTPUT_DIRS}

    shutil.copytree(source, destination, symlinks=False, ignore=ignore)


def analyze_source(
    source: Path,
    *,
    project: str = DEFAULT_PROJECT,
    expected_top: str = DEFAULT_TOP,
    expected_device: str = DEFAULT_DEVICE,
    enforce_known_hashes: bool = True,
    strict_c126_pin_schema: bool = True,
) -> tuple[dict[str, object], list[Issue]]:
    issues: list[Issue] = []
    qsf_path, qpf_path = find_project_files(source, project)
    model = parse_qsf(qsf_path)

    top_values = model.global_values("TOP_LEVEL_ENTITY")
    device_values = model.global_values("DEVICE")
    family_values = model.global_values("FAMILY")
    if top_values != [expected_top]:
        issues.append(Issue("ERROR", "TOP_MISMATCH", f"expected exactly TOP_LEVEL_ENTITY={expected_top!r}, got {top_values!r}", qsf_path.name))
    if device_values != [expected_device]:
        issues.append(Issue("ERROR", "DEVICE_MISMATCH", f"expected exactly DEVICE={expected_device!r}, got {device_values!r}", qsf_path.name))
    if family_values != ["Arria 10"]:
        issues.append(Issue("ERROR", "FAMILY_MISMATCH", f"expected FAMILY='Arria 10', got {family_values!r}", qsf_path.name))

    referenced: list[dict[str, object]] = []
    for assignment in model.globals:
        if assignment.name not in BUILD_REFERENCE_ASSIGNMENTS:
            continue
        resolved, reason = _safe_reference(source, assignment.value)
        record: dict[str, object] = {
            "assignment": assignment.name,
            "value": assignment.value,
            "line": assignment.line,
            "status": "unknown",
        }
        if reason == "dynamic":
            issues.append(Issue("ERROR", "DYNAMIC_BUILD_REFERENCE", f"cannot safely resolve non-literal build reference {assignment.value!r}", qsf_path.name, assignment.line))
            record["status"] = "dynamic"
        elif reason == "escape":
            issues.append(Issue("ERROR", "REFERENCE_ESCAPES_SOURCE", f"build reference escapes source root: {assignment.value!r}", qsf_path.name, assignment.line))
            record["status"] = "escape"
            record["resolved"] = str(resolved)
        else:
            assert resolved is not None
            record["resolved"] = str(resolved)
            if not resolved.is_file():
                issues.append(Issue("ERROR", "MISSING_REFERENCE", f"referenced file does not exist: {assignment.value!r}", qsf_path.name, assignment.line))
                record["status"] = "missing"
            else:
                relative_resolved = resolved.relative_to(source)
                if any(part in GENERATED_OUTPUT_DIRS for part in relative_resolved.parts):
                    issues.append(Issue("ERROR", "REFERENCE_IN_EXCLUDED_OUTPUT_DIR", f"required build reference is inside an excluded generated-output directory: {assignment.value!r}", qsf_path.name, assignment.line))
                    record["status"] = "excluded-output"
                else:
                    record["status"] = "present"
                    record["sha256"] = sha256_file(resolved)
        referenced.append(record)

    for name, value, line in model.external_path_hints:
        issues.append(
            Issue(
                "WARNING",
                "EXTERNAL_NONBUILD_PATH",
                f"QSF assignment {name} points outside the qii snapshot ({value}); verify whether that artifact is needed for simulation, not synthesis",
                qsf_path.name,
                line,
            )
        )

    pins: dict[str, str] = {}
    pin_to_ports: dict[str, list[str]] = {}
    duplicate_ports: dict[str, list[str]] = {}
    for assignment in model.locations:
        if assignment.port in pins:
            duplicate_ports.setdefault(assignment.port, [pins[assignment.port]]).append(assignment.pin)
        else:
            pins[assignment.port] = assignment.pin
        pin_to_ports.setdefault(assignment.pin, []).append(assignment.port)
    for port, assigned in sorted(duplicate_ports.items()):
        issues.append(Issue("ERROR", "DUPLICATE_PORT_LOCATION", f"port {port} has multiple location assignments: {assigned}", qsf_path.name))
    for pin, ports in sorted(pin_to_ports.items()):
        if len(ports) > 1:
            issues.append(Issue("ERROR", "DUPLICATE_PHYSICAL_PIN", f"physical pin {pin} is assigned to multiple ports: {ports}", qsf_path.name))

    indexed_observed: dict[str, set[int]] = {}
    unindexed_ports: list[str] = []
    for port in pins:
        base, index = _port_base_and_index(port)
        if index is None:
            unindexed_ports.append(port)
        else:
            indexed_observed.setdefault(base, set()).add(index)

    if strict_c126_pin_schema:
        if len(model.locations) != 136:
            issues.append(Issue("ERROR", "PIN_COUNT", f"expected 136 location assignments, got {len(model.locations)}", qsf_path.name))
        for base, expected in EXPECTED_INDEXED_PORTS.items():
            observed = frozenset(indexed_observed.get(base, set()))
            if observed != expected:
                issues.append(
                    Issue(
                        "ERROR",
                        "PIN_GROUP_MISMATCH",
                        f"{base}: expected indices {sorted(expected)}, got {sorted(observed)}",
                        qsf_path.name,
                    )
                )
        unexpected_bases = sorted(set(indexed_observed) - set(EXPECTED_INDEXED_PORTS))
        if unexpected_bases or unindexed_ports:
            issues.append(Issue("ERROR", "UNEXPECTED_PIN_PORT", f"unexpected location targets: bases={unexpected_bases}, unindexed={sorted(unindexed_ports)}", qsf_path.name))
        for port, expected_pin in EXPECTED_KEY_PINS.items():
            actual_pin = pins.get(port)
            if actual_pin != expected_pin:
                issues.append(Issue("ERROR", "KEY_PIN_MISMATCH", f"{port}: expected {expected_pin}, got {actual_pin}", qsf_path.name))

    global_io = model.global_values("DEVICE_IO_STANDARD_ALL")
    if global_io != ["1.2 V"]:
        issues.append(Issue("WARNING", "GLOBAL_IO_STANDARD_CHANGED", f"captured C126 used DEVICE_IO_STANDARD_ALL='1.2 V'; got {global_io!r}", qsf_path.name))
    issues.append(
        Issue(
            "WARNING",
            "GLOBAL_IO_STANDARD_IS_NOT_BOARD_QUALIFICATION",
            "the blanket 1.2 V assignment is generated source, not proof that DDR, F34 reference clock, U11 reset, or active-low LED banks match this ES3 PCB/P12-27065R electrical design",
            qsf_path.name,
        )
    )
    if not model.instance_io_standards:
        issues.append(Issue("WARNING", "NO_PER_PORT_IO_STANDARDS", "no per-port IO_STANDARD assignments were found; validate bank VCCIO, differential standards, termination and reference-clock topology against the exact schematic and EMIF pin plan", qsf_path.name))

    top_files = model.global_values("SYSTEMVERILOG_FILE")
    top_path: Path | None = None
    if top_files:
        candidate, reason = _safe_reference(source, top_files[0])
        if reason is None and candidate is not None and candidate.is_file():
            top_path = candidate
            if strict_c126_pin_schema:
                declared = parse_top_port_names(top_path)
                missing_top_ports = sorted({base for base in EXPECTED_INDEXED_PORTS if base not in declared})
                if missing_top_ports:
                    issues.append(Issue("ERROR", "TOP_PORTS_MISSING", f"top module is missing QSF-targeted ports: {missing_top_ports}", top_path.relative_to(source).as_posix()))
                inverted = _active_low_status_assignments(top_path)
                missing_inversions = sorted(set(STATUS_PORTS) - inverted)
                if missing_inversions:
                    issues.append(Issue("ERROR", "STATUS_NOT_ACTIVE_LOW", f"captured wrapper should invert all status LED outputs; missing inversions: {missing_inversions}", top_path.relative_to(source).as_posix()))
                else:
                    issues.append(Issue("INFO", "ACTIVE_LOW_STATUS", "all five calibration/traffic status outputs are explicitly inverted for active-low LEDs", top_path.relative_to(source).as_posix()))

    sdc_values = model.global_values("SDC_FILE")
    if sdc_values == ["jtag_example.sdc"]:
        issues.append(
            Issue(
                "WARNING",
                "JTAG_ONLY_TOP_LEVEL_SDC",
                "the explicit top-level SDC is the generated JTAG example; generated EMIF/IP constraints still require report review, and this file does not qualify the board reference clock, reset, or external electrical timing",
                qsf_path.name,
            )
        )

    if enforce_known_hashes:
        for relative, expected in KNOWN_C126_HASHES.items():
            path = source / relative
            if not path.is_file():
                issues.append(Issue("ERROR", "KNOWN_FILE_MISSING", f"captured C126 file is missing: {relative}", relative))
                continue
            actual = sha256_file(path)
            if actual != expected:
                issues.append(Issue("ERROR", "KNOWN_HASH_MISMATCH", f"{relative}: expected {expected}, got {actual}", relative))

    issues.extend(
        [
            Issue("WARNING", "UNVERIFIED_ES3_PRESET", "the generated project selects an ES3 device, while the earlier generation log reported an ES3/production-board-preset mismatch; inspect that log and regenerate only after exact board/card confirmation"),
            Issue("WARNING", "UNVERIFIED_OCT_MARGIN", "the earlier generation log reported reduced read-capture margin with periodic OCT recalibration disabled; this must be resolved before physical DDR acceptance"),
            Issue("WARNING", "NO_RECOVERY_IMAGE", "this source snapshot contains no verified board-specific recovery SOF/POF/JIC; a successful compile is not authority to program or flash"),
            Issue("WARNING", "NO_PHYSICAL_RESULT", "no synthesis/Fitter/timing result for this C126 example and no physical calibration/traffic result are supplied"),
        ]
    )

    report: dict[str, object] = {
        "tool": {"name": "c126_preflight", "version": TOOL_VERSION},
        "source": str(source),
        "project": project,
        "qsf": qsf_path.name,
        "qpf": qpf_path.name,
        "top_values": top_values,
        "device_values": device_values,
        "family_values": family_values,
        "location_assignment_count": len(model.locations),
        "key_pins": {port: pins.get(port) for port in EXPECTED_KEY_PINS},
        "global_io_standard": global_io,
        "per_port_io_standard_count": len(model.instance_io_standards),
        "referenced_files": referenced,
        "source_consistent": not any(issue.severity == "ERROR" for issue in issues),
        "physical_ready": False,
        "physical_ready_reason": "static source checks cannot certify PCB identity, electrical compatibility, DDR training/ECC, recovery, or safe programming",
    }
    return report, issues


def _write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def create_snapshot_run(
    source: Path,
    output: Path,
    *,
    project: str,
    expected_top: str,
    expected_device: str,
    enforce_known_hashes: bool,
    strict_c126_pin_schema: bool,
) -> tuple[Path, dict[str, object], list[Issue]]:
    source_r, output_r = require_disjoint_source_output(source, output)
    symlinks = scan_symlinks(source_r)
    if symlinks:
        displayed = [str(path.relative_to(source_r)) for path in symlinks[:20]]
        suffix = "" if len(symlinks) <= 20 else f" (+{len(symlinks) - 20} more)"
        raise PreflightError(f"source contains symlinks; refusing non-contained snapshot: {displayed}{suffix}")

    before_manifest = manifest(source_r)
    report, issues = analyze_source(
        source_r,
        project=project,
        expected_top=expected_top,
        expected_device=expected_device,
        enforce_known_hashes=enforce_known_hashes,
        strict_c126_pin_schema=strict_c126_pin_schema,
    )

    output_parent = output_r.parent
    output_parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output_r.name}.staging-", dir=output_parent))
    try:
        snapshot = staging / "snapshot"
        copy_snapshot(source_r, snapshot)
        after_manifest = manifest(snapshot)
        if before_manifest != after_manifest:
            raise PreflightError("snapshot manifest differs from source manifest")

        report.update(
            {
                "created_utc": _dt.datetime.now(tz=_dt.timezone.utc).isoformat(),
                "snapshot": "snapshot",
                "manifest_sha256": manifest_digest(before_manifest),
                "manifest_file_count": len(before_manifest),
                "issues": [issue.as_dict() for issue in issues],
                "actions_not_performed": [
                    "FPGA programming or flash update",
                    "JTAG access",
                    "PCIe BAR access or bus-master enable",
                    "kernel driver binding or module loading",
                    "license file or license service changes",
                    "physical-readiness certification",
                ],
            }
        )
        _write_json(staging / "preflight.json", report)
        _write_json(staging / "manifest.json", before_manifest)
        (staging / "manifest.sha256").write_text(report["manifest_sha256"] + "  manifest.json\n", encoding="utf-8")
        staging.rename(output_r)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    return output_r / "snapshot", report, issues


def resolve_executable(command: str) -> Path:
    if os.sep in command:
        path = Path(command).expanduser().resolve(strict=True)
    else:
        found = shutil.which(command)
        if found is None:
            raise PreflightError(f"executable not found in PATH: {command}")
        path = Path(found).resolve(strict=True)
    if not path.is_file() or not os.access(path, os.X_OK):
        raise PreflightError(f"not an executable regular file: {path}")
    return path


def design_closure(report: str) -> dict:
    """Read the captured TimeQuest table; missing/ambiguous evidence fails closed.

    Passing this table is a static timing gate, never physical acceptance.
    """
    lines = report.splitlines()
    # Column widths can vary with Quartus version; recognize the one-cell title.
    starts = [i for i, line in enumerate(lines)
              if line.startswith(';') and
              [c.strip() for c in line.split(';')[1:-1]] == ['Design Closure Summary']]
    if len(starts) != 1:
        return {'state': 'unknown', 'reason': 'missing/ambiguous design closure table'}
    flags = {}
    closed = False
    for line in lines[starts[0] + 1:]:
        if line.startswith('+'):
            if flags:
                closed = True
                break
            continue
        cells = [c.strip() for c in line.split(';')[1:-1]]
        if cells == ['Panel Name', 'Result Flag']:
            continue
        if len(cells) != 2 or cells[0] in flags or cells[1] not in ('Pass', 'Fail', 'Not Found'):
            return {'state': 'unknown', 'reason': 'unsupported/duplicate closure row'}
        flags[cells[0]] = cells[1]
    required = ('Design Closure Summary', 'Timing Closure', 'Setup Summary',
                'Hold Summary', 'Recovery Summary', 'Removal Summary',
                'Minimum Pulse Width Summary', 'Double Data Rate (DDR) Summary',
                'Unconstrained Paths')
    if not closed:
        return {'state': 'unknown', 'reason': 'unterminated closure table'}
    missing = [name for name in required if name not in flags]
    if missing:
        return {'state': 'unknown', 'reason': 'missing required closure rows', 'missing': missing, 'flags': flags}
    passed = all(flags[name] == 'Pass' for name in required) and 'Fail' not in flags.values()
    return {'state': 'passed' if passed else 'failed', 'flags': flags}


def run_quartus_compile(
    snapshot: Path,
    output: Path,
    *,
    project: str,
    quartus_sh: str,
    environment: Mapping[str, str] | None = None,
) -> int:
    executable = resolve_executable(quartus_sh)
    report_paths = [snapshot / f'{project}.sta.rpt', snapshot / 'output_files' / f'{project}.sta.rpt']
    if any(path.exists() for path in report_paths):
        raise PreflightError('pre-existing STA report in build snapshot; refuse stale closure evidence')
    command = [str(executable), "--flow", "compile", project]
    started = _dt.datetime.now(tz=_dt.timezone.utc)
    completed = subprocess.run(
        command,
        cwd=snapshot,
        env=dict(environment) if environment is not None else None,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        shell=False,
    )
    ended = _dt.datetime.now(tz=_dt.timezone.utc)
    (output / "quartus.stdout.log").write_text(completed.stdout, encoding="utf-8")
    (output / "quartus.stderr.log").write_text(completed.stderr, encoding="utf-8")
    reports = [path for path in report_paths if path.is_file()]
    closure = {'state': 'unknown', 'reason': 'missing/ambiguous STA report'}
    if len(reports) == 1:
        closure = design_closure(reports[0].read_text(encoding='utf-8', errors='strict'))
        closure.update(report=str(reports[0]), sha256=sha256_file(reports[0]))
    wrapper_exit = completed.returncode or (0 if closure['state'] == 'passed' else 2)
    result = {
        "command": command,
        "cwd": str(snapshot),
        "quartus_sh_sha256": sha256_file(executable),
        "started_utc": started.isoformat(),
        "ended_utc": ended.isoformat(),
        "exit_code": completed.returncode,
        "wrapper_exit_code": wrapper_exit,
        "design_closure": closure,
        "programming_performed": False,
        "physical_acceptance_claimed": False,
    }
    _write_json(output / "build-result.json", result)
    return wrapper_exit


def _common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--source", required=True, type=Path, help="C126 qii source directory")
    parser.add_argument("--output", required=True, type=Path, help="new, dedicated output directory")
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--expect-top", default=DEFAULT_TOP)
    parser.add_argument("--expect-device", default=DEFAULT_DEVICE)
    parser.add_argument("--skip-known-hashes", action="store_true", help="allow non-byte-identical fixtures/derived sources; differences remain visible in your own review")
    parser.add_argument("--generic-pin-schema", action="store_true", help="do not enforce the captured 136-port C126 pin schema")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)

    preflight = sub.add_parser("preflight", help="validate and snapshot only; never invoke Quartus")
    _common_arguments(preflight)

    build = sub.add_parser("build", help="validate, snapshot, then run quartus_sh --flow compile in the snapshot")
    _common_arguments(build)
    build.add_argument("--quartus-sh", default="quartus_sh", help="path/name of the intended Quartus quartus_sh executable")
    build.add_argument(
        "--acknowledge-unverified-physical-constraints",
        action="store_true",
        help="required acknowledgement that compilation does not qualify the generated pins/IO standards or authorize programming",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.action == "build" and not args.acknowledge_unverified_physical_constraints:
            raise PreflightError("build requires --acknowledge-unverified-physical-constraints")

        snapshot, report, issues = create_snapshot_run(
            args.source,
            args.output,
            project=args.project,
            expected_top=args.expect_top,
            expected_device=args.expect_device,
            enforce_known_hashes=not args.skip_known_hashes,
            strict_c126_pin_schema=not args.generic_pin_schema,
        )
        error_count = sum(issue.severity == "ERROR" for issue in issues)
        warning_count = sum(issue.severity == "WARNING" for issue in issues)
        print(f"preflight: errors={error_count} warnings={warning_count} output={args.output}")
        if error_count:
            return 2
        if args.action == "preflight":
            return 0
        return run_quartus_compile(
            snapshot,
            args.output.resolve(strict=True),
            project=args.project,
            quartus_sh=args.quartus_sh,
        )
    except (OSError, ValueError, PreflightError) as exc:
        print(f"c126_preflight: {exc}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
