#!/usr/bin/env python3
"""Generator guard tests using an explicitly synthetic text fixture, not HDL.

The test-only digest substitution below permits exercising packaging without
redistributing the large vendor packet. Production has no digest override.
These tests are not a native compile, simulation, or source-bound proof.
"""
import difflib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cra_fix", ROOT / "tools/cra_read_clear_safe.py")
fix = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fix)


def fixture_source():
    return (
        "// ------------------------------------------------------------------------- \n"
        "// SystemVerilog created from Pass1Kernel_function_cra_agent\n"
        "// Created for function/kernel Pass1Kernel\n"
        "module Pass1Kernel_function_cra_agent (\n"
        + "\n".join(fix.REQUIRED) + "\n"
        + fix.DECL_ANCHOR + fix.LOGIC_ANCHOR + fix.OLD_CLEAR + fix.OLD_READ
        + "endmodule\n"
    )


def fixture_packet(first):
    second = first.replace("Pass1Kernel", "Pass2Kernel")
    diff = "".join(difflib.unified_diff(
        first.splitlines(keepends=True), second.splitlines(keepends=True),
        fromfile=fix.PACKET_PREFIX + fix.RELATIVE[0],
        tofile=fix.PACKET_PREFIX + fix.RELATIVE[1],
    ))
    packet = ("SYNTHETIC GUARD-TEST FIXTURE\n" + first
              + fix.DIFF_MARKER + diff + fix.TEST_MARKER
              + "module cra_completion_race_tb;\nendmodule\n"
              + fix.SCRIPT_MARKER + "#!/usr/bin/env bash\n").encode()
    return packet, second


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "immutable-source"
        self.output = self.root / "candidate"
        self.packet = self.root / "packet.txt"
        first = fixture_source()
        raw, second = fixture_packet(first)
        self.packet.write_bytes(raw)
        self.raw = raw
        for relative, text in zip(fix.RELATIVE, (first, second)):
            file = self.source / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(text.encode())

    def generate_fixture(self, output=None):
        # This mocking is confined to the guard-test process.
        with patch.object(fix, "PACKET_SHA256", fix.sha(self.raw)):
            return fix.generate(self.packet, self.source, output or self.output)

    def test_production_pin_rejects_fixture(self):
        with self.assertRaisesRegex(fix.Refused, "SHA-256 mismatch"):
            fix.generate(self.packet, self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_both_candidates_and_immutable_inputs(self):
        before = [(self.source / p).read_bytes() for p in fix.RELATIVE]
        result = self.generate_fixture()
        self.assertEqual(len(result["files"]), 2)
        self.assertEqual(result["verification"]["transport_read_clear_safe"], "open")
        self.assertEqual((self.output / "reference/cra_completion_race_tb.sv").read_text(),
                         "module cra_completion_race_tb;\nendmodule\n")
        self.assertEqual(json.loads((self.output / "manifest.json").read_text()), result)
        for index, relative in enumerate(fix.RELATIVE):
            self.assertEqual((self.source / relative).read_bytes(), before[index])
            candidate = (self.output / relative).read_text()
            self.assertIn(fix.NEW_CLEAR, candidate)
            self.assertIn(fix.NEW_READ, candidate)
            self.assertEqual(candidate.count(fix.NEW_LOGIC), 1)
            self.assertEqual(candidate.count(fix.NEW_DECLS), 1)
            self.assertEqual(fix.sha((self.output / relative).read_bytes()),
                             result["files"][index]["candidate_sha256"])

    def test_packet_corruption_rejected(self):
        self.packet.write_bytes(self.raw + b"changed")
        with self.assertRaisesRegex(fix.Refused, "SHA-256 mismatch"):
            self.generate_fixture()
        self.assertFalse(self.output.exists())

    def test_source_corruption_rejected_before_any_output(self):
        file = self.source / fix.RELATIVE[1]
        file.write_bytes(file.read_bytes().replace(b"& running_bit_b", b"| running_bit_b"))
        with self.assertRaisesRegex(fix.Refused, "source body mismatch"):
            self.generate_fixture()
        self.assertFalse(self.output.exists())

    def test_duplicate_anchor_rejected(self):
        with self.assertRaisesRegex(fix.Refused, "exactly one"):
            fix.transform(fixture_source() + fix.OLD_CLEAR, 1)

    def test_already_transformed_rejected(self):
        candidate = fix.transform(fixture_source(), 1)
        with self.assertRaisesRegex(fix.Refused, "already transformed"):
            fix.transform(candidate, 1)

    def test_unreviewed_width_rejected(self):
        text = fixture_source().replace("reg [1:0] finish_counter_", "reg [2:0] finish_counter_")
        with self.assertRaises(fix.Refused):
            fix.transform(text, 1)

    def test_existing_output_is_untouched(self):
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(fix.Refused, "already exist"):
            self.generate_fixture()
        self.assertEqual(sentinel.read_text(), "keep")

    def test_output_alias_into_immutable_tree_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(fix.Refused, "isolated"):
            self.generate_fixture(alias / "candidate")
        self.assertFalse((self.source / "candidate").exists())

    def test_source_symlink_escape_rejected(self):
        file = self.source / fix.RELATIVE[1]
        external = self.root / "outside.sv"
        external.write_bytes(file.read_bytes())
        file.unlink()
        file.symlink_to(external)
        with self.assertRaisesRegex(fix.Refused, "symlink escapes"):
            self.generate_fixture()
        self.assertFalse(self.output.exists())

    def test_only_terminal_empty_lf_lines_are_compatible(self):
        file = self.source / fix.RELATIVE[0]
        file.write_bytes(file.read_bytes() + b"\n\n")
        self.generate_fixture()
        self.assertTrue((self.output / fix.RELATIVE[0]).read_bytes().endswith(b"\n\n\n"))

    def test_crlf_is_not_silently_normalized(self):
        file = self.source / fix.RELATIVE[0]
        file.write_bytes(file.read_bytes().replace(b"\n", b"\r\n"))
        with self.assertRaisesRegex(fix.Refused, "source body mismatch"):
            self.generate_fixture()
        self.assertFalse(self.output.exists())

    def test_wrong_diff_context_rejected(self):
        first = fixture_source()
        _, tail = self.raw.decode().split(fix.DIFF_MARKER)
        diff = tail.split(fix.TEST_MARKER)[0].rstrip("\n") + "\n"
        corrupted = diff.replace("-module Pass1Kernel", "-module BadKernel")
        with self.assertRaisesRegex(fix.Refused, "context mismatch"):
            fix.apply_packet_diff(first, corrupted)

    def test_runner_refuses_immutable_build_before_writing_logs(self):
        repository = self.root / "runner-repository"
        script = repository / "tests/vcs/run_cra_read_clear_safe.sh"
        script.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "tests/vcs/run_cra_read_clear_safe.sh", script)
        immutable = repository / "qualification/kernel-system-vcs-v1/source"
        immutable.mkdir(parents=True)
        alias = self.root / "source-alias"
        alias.symlink_to(immutable, target_is_directory=True)
        for build in (immutable / "illegal-build", alias / "illegal-alias-build"):
            with self.subTest(build=build):
                result = subprocess.run(
                    ["bash", str(script), str(self.packet), str(build)],
                    capture_output=True, text=True, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("isolated from immutable compiler sources", result.stderr)
                self.assertFalse(build.exists())
        self.assertEqual(list(immutable.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
