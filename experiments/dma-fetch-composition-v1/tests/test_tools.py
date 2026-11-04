#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Tool/guard tests only. These are not native RTL execution or formal proof."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    if spec is None or spec.loader is None:
        raise RuntimeError(relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = load("composition_builder_under_test", "tools/build.py")
runner = load("composition_runner_under_test", "tests/run_vcs.py")


class CompositionToolsTests(unittest.TestCase):
    def test_exact_pass_requires_correct_scenario_and_clean_log(self):
        marker = "PASS dma-fetch-composition-v1 scenario=0 case=mixed requests=2\n"
        self.assertTrue(runner.passed_run(0, marker, 0, "mixed"))
        for code, text in (
            (1, marker), (0, "some other suite PASS\n"),
            (0, marker.replace("scenario=0", "scenario=1")),
            (0, marker.replace("case=mixed", "case=mixed_other")),
            (0, marker + marker), (0, "prefix " + marker),
            (0, marker + "Fatal: data mismatch\n"),
            (0, "Error! Unknown INTENDED_DEVICE_FAMILY=Stratix V.\n" + marker),
            (0, marker + "Error: illegal state\n"),
            (0, "Error-[SE] invalid source\n" + marker),
            (0, marker + "assertion failed\n"),
            (0, marker + "Assertion dut.no_early_receipt violated\n"),
        ):
            with self.subTest(code=code, text=text):
                self.assertFalse(runner.passed_run(code, text, 0, "mixed"))

    def test_order_witness_requires_unique_exact_native_failure(self):
        diagnostic = "EXPECTED_ORDER_VIOLATION expected=1 actual=2"
        for code, text in (
            (0, "Fatal: " + diagnostic + "\n"),
            (1, "Fatal: bench.sv, 12: tb at time 200\n" + diagnostic + "\n"),
        ):
            with self.subTest(code=code, text=text):
                self.assertTrue(runner.witnessed_order_failure(code, text))
        for code, text in (
            (-9, "Fatal: " + diagnostic), (127, "Fatal: " + diagnostic),
            (0, diagnostic), (0, "Fatal: unrelated\n\n" + diagnostic),
            (0, "Fatal: EXPECTED_ORDER_VIOLATION expected=2 actual=2"),
            (0, "Fatal: EXPECTED_ORDER_VIOLATION expected=01 actual=1"),
            (0, "Fatal: EXPECTED_ORDER_VIOLATION"),
            (0, "Fatal: EXPECTED_ORDER_VIOLATION expected=x actual=2"),
            (0, "Fatal: " + diagnostic + "\nFatal: secondary failure"),
            (0, "Fatal: " + diagnostic + "\nError! incompatible model"),
            (0, "Fatal: " + diagnostic + "\nassertion failure"),
            (0, "PASS dma-fetch-composition-v1\nFatal: " + diagnostic),
            (0, diagnostic + "\nFatal: unrelated"),
        ):
            with self.subTest(code=code, text=text):
                self.assertFalse(runner.witnessed_order_failure(code, text))

    def test_owned_consumer_pass_cannot_stand_in_for_native_composition(self):
        marker = "PASS consumer-order-v1 read=4 write=4 commits=4 receipts=4\n"
        self.assertTrue(runner.passed_consumer_run(0, marker))
        self.assertFalse(runner.passed_run(0, marker, 1, "queued_wrap_order"))
        for code, text in ((1, marker), (0, marker + marker),
                           (0, marker.replace("receipts=4", "receipts=3")),
                           (0, marker + "Fatal: extra emit\n")):
            with self.subTest(code=code, text=text):
                self.assertFalse(runner.passed_consumer_run(code, text))

    def test_frozen_dependency_bytes_match_the_checked_out_pin(self):
        builder.verify_dependencies()

    def test_bad_private_engine_is_rejected_before_transform(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fake-engine.sv"
            path.write_bytes(b"module synthetic; endmodule\n")
            with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                builder.read_exact(path, builder.ENGINE_V4_SHA)

    def test_dependency_mutation_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in builder.DEPENDENCIES:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((builder.REPO / relative).read_bytes())
            relative = "experiments/dma-fetch-v4/rtl/controller_tx_v4.svh"
            target = root / relative
            target.write_bytes(target.read_bytes().replace(b"v4_tx_fire", b"v4_tx_wrong", 1))
            with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                builder.verify_dependencies(root)

    def test_missing_or_empty_source_is_not_a_valid_seed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "missing.sv"
            with self.assertRaises(ValueError):
                builder.read_exact(path)
            path.touch()
            with self.assertRaises(ValueError):
                builder.read_exact(path)

    def test_private_output_rejects_git_and_input_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / "checkout"
            checkout.mkdir()
            (checkout / ".git").write_text("gitdir: elsewhere\n")
            with self.assertRaisesRegex(ValueError, "Git"):
                builder.private_output(checkout / "generated", [])
            input_tree = root / "private-inputs"
            input_tree.mkdir()
            with self.assertRaisesRegex(ValueError, "overlaps"):
                builder.private_output(input_tree / "generated", [input_tree])
            self.assertEqual(builder.private_output(root / "generated", [input_tree]), root / "generated")

    def test_launcher_symlink_retains_dispatch_basename(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dispatch = root / "dispatch"
            dispatch.write_text("#!/bin/sh\nexit 0\n")
            dispatch.chmod(0o700)
            vcs = root / "vcs"
            vcs.symlink_to(dispatch)
            self.assertEqual(runner.command(str(vcs)), [str(vcs)])

    def test_missing_tool_reports_unavailable_not_executed(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = str(Path(directory) / "vcs")
            with self.assertRaises(FileNotFoundError):
                runner.command(missing)
            self.assertEqual(runner.command(missing, prepare=True), [missing])

    def test_frozen_token_anchor_rejects_missing_or_duplicate(self):
        # Small synthetic spans test only the anchor matcher. They never pass
        # a private-source hash gate and are not substitutes for native RTL.
        upstream = builder.load_v5()
        replace = upstream.V4.tokens
        source = "prefix\r\n  old_signal = 1;\r\nsuffix\n"
        self.assertEqual(replace(source, "old_signal = 1;", "new_signal = 2;"),
                         "prefix\r\n  new_signal = 2;\r\nsuffix\n")
        for text in ("missing;", "old_signal = 1; old_signal = 1;"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                replace(text, "old_signal = 1;", "new_signal = 2;")

    def test_order_repair_uses_real_owned_seed_and_preserves_other_files(self):
        upstream = builder.load_v5()
        repair = load("composition_repair_under_test", "tools/repair.py")
        original = upstream.consumer()
        self.assertEqual(builder.sha(original.encode()), repair.CONSUMER_SHA256)
        inputs = {repair.CONSUMER_NAME: original, "untouched.svh": "prefix\r\nsuffix\n"}
        result = repair.derive(inputs)
        self.assertIsNot(result, inputs)
        self.assertEqual(inputs[repair.CONSUMER_NAME], original)
        self.assertEqual(result["untouched.svh"], inputs["untouched.svh"])
        self.assertNotEqual(result[repair.CONSUMER_NAME], original)
        self.assertIn(repair.NEW_PICKER, result[repair.CONSUMER_NAME])
        self.assertNotIn(repair.OLD_PICKER, result[repair.CONSUMER_NAME])
        with self.assertRaisesRegex(ValueError, "exact pinned"):
            repair.repair_consumer(original + "\n")
        with self.assertRaises(ValueError):
            repair.derive({"untouched.svh": "not a consumer"})

    def test_order_repair_unique_anchor_preserves_other_bytes(self):
        repair = load("composition_repair_anchor_under_test", "tools/repair.py")
        self.assertEqual(repair.once("prefix\r\nold;\r\nsuffix", "old;", "new;"),
                         "prefix\r\nnew;\r\nsuffix")
        for source in ("other;", "old; old;"):
            with self.subTest(source=source), self.assertRaises(ValueError):
                repair.once(source, "old;", "new;")


if __name__ == "__main__":
    unittest.main()
