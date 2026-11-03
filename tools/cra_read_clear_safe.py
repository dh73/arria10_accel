#!/usr/bin/env python3
"""Generate isolated CRA candidates from the exact reviewed source packet.

Never writes the compiler source tree. No hash override or fuzzy-match mode.
The packet SHA is supplied by request 321f7386-e836-4b4b-8b3d-5ea608261b5c.
This program generates a candidate; it does not certify read_clear_safe.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys


PACKET_SHA256 = "b1ab68c0843424be3b1e09a832b54d6c04c95c3643fc98ddaea0297cfc298a40"
REQUEST_ID = "321f7386-e836-4b4b-8b3d-5ea608261b5c"
RELATIVE = tuple(
    f"kernel_hdl/Pass{k}Kernel/Pass{k}Kernel_function_cra_agent.sv"
    for k in (1, 2)
)
PACKET_PREFIX = "qualification/kernel-system-vcs-v1/source/"
DIFF_MARKER = "\nPASS1 TO PASS2 DIFF\n"
TEST_MARKER = "\nFILE tests/vcs/cra_completion_race_tb.sv\n"
SCRIPT_MARKER = "\nFILE tests/vcs/run_cra_completion_race.sh\n"

DECL_ANCHOR = "    reg [0:0] clear_finish_counter_reg_q;\n"
NEW_DECLS = """    // READ_CLEAR_SAFE_V1: retire the previous read's actual snapshot.
    reg [1:0] read_clear_safe_snapshot_q;
    wire [1:0] read_clear_safe_visible_q;
    wire [1:0] read_clear_safe_after_retire_q;
"""
LOGIC_ANCHOR = "    // clear_on_read_mux(MUX,79)\n"
NEW_LOGIC = """    // READ_CLEAR_SAFE_V1: D is the existing delayed read flag. C and
    // snapshot are two bits, so both subtractions are modulo four.
    // Visible = C - (D ? snapshot : 0); a read returns this pre-edge value.
    assign read_clear_safe_visible_q = clear_finish_counter_reg_q
        ? (finish_counter_NO_SHIFT_REG_q - read_clear_safe_snapshot_q)
        : finish_counter_NO_SHIFT_REG_q;
    assign read_clear_safe_after_retire_q =
        adder_counter_width_b - read_clear_safe_snapshot_q;

    // Capture the value returned, including exclusion of a prior read.
    // Hold when there is no read; the existing delayed flag gates its use.
    always_ff @ (posedge clock or negedge resetn)
    begin
        if (!resetn)
            read_clear_safe_snapshot_q <= 2'b00;
        else if (clear_finish_counter_pre_comp_q == 1'b1)
            read_clear_safe_snapshot_q <= read_clear_safe_visible_q;
    end

"""
OLD_CLEAR = "            1'b1 : clear_on_read_mux_q = clear_or_finish_q;\n"
NEW_CLEAR = "            1'b1 : clear_on_read_mux_q = read_clear_safe_after_retire_q;\n"
OLD_READ = "    assign padded_finish_counter_q = {const_finish_counter_padding_q, finish_counter_NO_SHIFT_REG_q};\n"
NEW_READ = "    assign padded_finish_counter_q = {const_finish_counter_padding_q, read_clear_safe_visible_q};\n"

# Full-file comparison is the primary guard. These additional guards explain
# which semantic/ABI shape this particular transformation requires.
REQUIRED = (
    "High Level Design Compiler for Intel(R) FPGAs Version 2025.0 (Release Build #4f8f97ee91)",
    "    reg [1:0] finish_counter_NO_SHIFT_REG_q;\n",
    "    input wire [4:0] avs_cra_address,\n",
    "    input wire [7:0] avs_cra_byteenable,\n",
    "    output wire [63:0] avs_cra_readdata,\n",
    "    assign finish_counter_addr_q = 5'b00110;\n",
    "    assign clear_finish_counter_pre_comp_q = is_finish_counter_addr_q & avs_cra_read;\n",
    "            clear_finish_counter_reg_q <= clear_finish_counter_pre_comp_q;\n",
    "    assign clear_on_read_mux_s = clear_finish_counter_reg_q;\n",
    "    assign incrementor_a = {1'b0, finish_counter_NO_SHIFT_REG_q};\n",
    "    assign incrementor_b = {2'b00, finish_pulse_while_running_q};\n",
    "    assign adder_counter_width_b = incrementor_q[1:0];\n",
    "    assign finish_pulse_q = not_last_finish_state_q & kernel_done;\n",
    "    assign finish_pulse_while_running_q = finish_pulse_q & running_bit_b;\n",
    "            finish_counter_NO_SHIFT_REG_q <= $unsigned(2'b00);\n",
    "            finish_counter_NO_SHIFT_REG_q <= clear_on_read_mux_q;\n",
    "            cra_output_readdatavalid_reg_q <= avs_cra_read;\n",
    "            cra_output_readdata_reg_q <= readdata_output_mux_2_q;\n",
    "    assign cra_irq = done_or_printf_or_profile_irq_signal_q;\n",
)


class Refused(ValueError):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def exactly_once(text: str, needle: str) -> None:
    if text.count(needle) != 1:
        raise Refused(f"expected exactly one source anchor: {needle!r}")


def apply_packet_diff(original: str, patch: str) -> str:
    """Apply the supplied one-file unified diff with exact positions/context."""
    lines = patch.splitlines(keepends=True)
    if len(lines) < 3 or lines[:2] != [
        f"--- {PACKET_PREFIX}{RELATIVE[0]}\n",
        f"+++ {PACKET_PREFIX}{RELATIVE[1]}\n",
    ]:
        raise Refused("unexpected Pass1-to-Pass2 diff paths")
    source = original.splitlines(keepends=True)
    result: list[str] = []
    cursor, pos, hunks = 0, 2, 0
    while pos < len(lines):
        match = re.fullmatch(r"@@ -(\d+),(\d+) \+(\d+),(\d+) @@\n", lines[pos])
        if not match:
            raise Refused("unexpected unified-diff hunk header")
        old_line, old_count, new_line, new_count = map(int, match.groups())
        start = old_line - 1
        if not cursor <= start <= len(source):
            raise Refused("overlapping/out-of-range diff hunk")
        result.extend(source[cursor:start])
        if len(result) != new_line - 1:
            raise Refused("unexpected new-file hunk position")
        cursor, pos = start, pos + 1
        used_old = used_new = 0
        while pos < len(lines) and not lines[pos].startswith("@@ "):
            line = lines[pos]
            pos += 1
            if not line or line[0] not in " +-":
                raise Refused("unexpected diff payload")
            kind, body = line[0], line[1:]
            if kind in " -":
                if cursor >= len(source) or source[cursor] != body:
                    raise Refused("Pass1-to-Pass2 context mismatch")
                cursor += 1
                used_old += 1
            if kind in " +":
                result.append(body)
                used_new += 1
        if (used_old, used_new) != (old_count, new_count):
            raise Refused("incorrect unified-diff hunk lengths")
        hunks += 1
    if hunks != 1:
        raise Refused("reviewed packet requires exactly one rename-only hunk")
    result.extend(source[cursor:])
    return "".join(result)


def packet_sources(raw: bytes) -> tuple[str, str]:
    if sha(raw) != PACKET_SHA256:
        raise Refused("source-packet SHA-256 mismatch; no hash override is supported")
    try:
        packet = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Refused("packet is not UTF-8") from error
    for marker in (DIFF_MARKER, TEST_MARKER):
        exactly_once(packet, marker)
    prefix, tail = packet.split(DIFF_MARKER)
    # Preserve the entire vendor header. Text before it is packet framing.
    start = prefix.find("// ------------------------------------------------------------------------- ")
    if start < 0:
        raise Refused("missing original compiler header")
    original = prefix[start:].rstrip("\n") + "\n"
    if original.count("\nendmodule\n") != 1 or not original.endswith("\nendmodule\n"):
        raise Refused("packet does not contain exactly one complete original CRA")
    patch = tail.split(TEST_MARKER)[0].rstrip("\n") + "\n"
    second = apply_packet_diff(original, patch)
    if original.count("Pass1Kernel") != 3 or second != original.replace("Pass1Kernel", "Pass2Kernel"):
        raise Refused("Pass2 differs by more than the three reviewed name substitutions")
    return original, second


def transform(source: str, kernel: int) -> str:
    """Internal exact-shape edit; CLI first verifies every source body byte."""
    if "read_clear_safe_" in source or "READ_CLEAR_SAFE_V1" in source:
        raise Refused("source is already transformed")
    for needle in REQUIRED + (DECL_ANCHOR, LOGIC_ANCHOR, OLD_CLEAR, OLD_READ):
        exactly_once(source, needle)
    exactly_once(source, f"module Pass{kernel}Kernel_function_cra_agent (\n")
    replacements = (
        (DECL_ANCHOR, DECL_ANCHOR + NEW_DECLS),
        (LOGIC_ANCHOR, NEW_LOGIC + LOGIC_ANCHOR),
        (OLD_CLEAR, NEW_CLEAR),
        (OLD_READ, NEW_READ),
    )
    output = source
    for old, new in replacements:
        output = output.replace(old, new, 1)
    # Inverse edit verifies that nothing outside the four sites was changed.
    restored = output
    for old, new in reversed(replacements):
        exactly_once(restored, new)
        restored = restored.replace(new, old, 1)
    if restored != source:
        raise Refused("transformation changed unrelated bytes")
    return output


def generate(packet: Path, source_root: Path, output_dir: Path) -> dict:
    packet_raw = packet.read_bytes()
    expected = packet_sources(packet_raw)
    packet_text = packet_raw.decode("utf-8")
    exactly_once(packet_text, SCRIPT_MARKER)
    baseline = packet_text.split(TEST_MARKER)[1].split(SCRIPT_MARKER)[0].rstrip("\n") + "\n"
    exactly_once(baseline, "module cra_completion_race_tb;")
    exactly_once(baseline, "endmodule")
    source_root = source_root.resolve(strict=True)
    output_dir = output_dir.absolute()
    # Resolve parent aliases before writes; disallow both nesting directions.
    resolved_out = output_dir.resolve()
    if (resolved_out == source_root or source_root in resolved_out.parents
            or resolved_out in source_root.parents):
        raise Refused("candidate output must be isolated from the immutable source tree")
    if output_dir.exists() or output_dir.is_symlink():
        raise Refused("candidate output must not already exist")
    inputs: list[tuple[Path, bytes]] = []
    candidates: list[tuple[str, bytes]] = []
    files = []
    for index, relative in enumerate(RELATIVE):
        source_path = source_root / relative
        actual_path = source_path.resolve(strict=True)
        if source_root not in actual_path.parents:
            raise Refused("source symlink escapes the declared source tree")
        raw = source_path.read_bytes()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as error:
            raise Refused(f"not UTF-8: {relative}") from error
        # The packet delimiter cannot distinguish final empty LF lines. Only
        # those are ignored for binding; all other source bytes must match.
        # CRLF, BOMs, timestamps, comments and whitespace changes are refused.
        if not text.endswith("\n") or text.rstrip("\n") != expected[index].rstrip("\n"):
            raise Refused(f"exact reviewed source body mismatch: {relative}")
        edited = transform(text, index + 1).encode("utf-8")
        inputs.append((source_path, raw))
        candidates.append((relative, edited))
        files.append({
            "source_relative": relative,
            "candidate_relative": relative,
            "source_sha256": sha(raw),
            "candidate_sha256": sha(edited),
            "source_bytes": len(raw),
            "candidate_bytes": len(edited),
        })
    manifest = {
        "schema": 1,
        "request_id": REQUEST_ID,
        "transformation": "cra-delayed-snapshot-retirement-v1",
        "packet_sha256": PACKET_SHA256,
        "compatibility": "exact UTF-8 LF source body; final empty LF lines preserved",
        "counter_bits": 2,
        "baseline_tb_sha256": sha(baseline.encode("utf-8")),
        "read_latency_edges": 1,
        "read_event": "avs_cra_read && avs_cra_address == 5'd6",
        "verification": {
            "vcs": "not_run_by_generator",
            "lean": "not_run_by_generator",
            "transport_read_clear_safe": "open",
            "whole_kernel_reachability": "open",
            "physical_and_platform_requirements": "open",
        },
        "files": files,
    }
    # No filesystem writes occur until both inputs and all edits are checked.
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir()  # exclusive creation; never reuse a previous candidate
    try:
        for relative, data in candidates:
            destination = output_dir / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        reference = output_dir / "reference"
        reference.mkdir()
        (reference / "cra_completion_race_tb.sv").write_text(baseline, encoding="utf-8")
        changes = []
        for (path, before), (relative, after) in zip(inputs, candidates):
            if path.read_bytes() != before:
                raise Refused("compiler input changed concurrently during generation")
            changes.extend(difflib.unified_diff(
                before.decode().splitlines(keepends=True),
                after.decode().splitlines(keepends=True),
                fromfile="original/" + relative, tofile="candidate/" + relative,
            ))
        (output_dir / "generated-cra.diff").write_text("".join(changes), encoding="utf-8")
        # Written last: an incomplete directory has no completed manifest.
        (output_dir / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    except BaseException:
        shutil.rmtree(output_dir)
        raise
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packet", required=True, type=Path)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        manifest = generate(args.packet, args.source_root, args.output_dir)
    except (OSError, Refused) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
