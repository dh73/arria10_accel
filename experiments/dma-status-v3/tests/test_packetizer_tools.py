#!/usr/bin/env python3
"""Owned runner/guard unit tests; these do not execute or qualify vendor RTL.

No supplied source pin is patched or bypassed. Synthetic replacement examples
exercise only the low-level unique-span operation, never a positive original
vendor transformation. Native qualification requires run_packetizer_vcs.py.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load('packetizer_runner_under_test', 'tests/run_packetizer_vcs.py')
builder = load('packetizer_builder_under_test', 'tools/build_packetizer.py')


class PacketizerToolsTests(unittest.TestCase):
    def test_positive_result_requires_clean_success(self):
        for code, text, expected in (
            (0, 'NATIVE_D2H_PACKETIZER_PASS descriptors=1\n', True),
            (1, 'NATIVE_D2H_PACKETIZER_PASS\n', False),
            (0, 'some other suite passed\n', False),
            (0, 'Error! model failure\nNATIVE_D2H_PACKETIZER_PASS\n', False),
            (0, 'NATIVE_D2H_PACKETIZER_PASS\nFatal: corrupted data\n', False),
            (0, 'NATIVE_D2H_PACKETIZER_PASS\nError-[SE] invalid\n', False),
        ):
            with self.subTest(code=code, text=text):
                self.assertEqual(runner.passed_run(code, text, False), expected)

    def test_status_witness_requires_its_native_fatal(self):
        diagnostic = ('D2H_STATUS_EARLY descriptor=0 enqueued=0 '
                      'required=4 tx_write=0')
        for code, text, expected in (
            (1, f'Fatal: {diagnostic}\n', True),
            (1, f'Fatal: source.sv, 1: tb: at time 10\n{diagnostic}\n', True),
            (0, f'Fatal: {diagnostic}\n', True),
            (-9, f'Fatal: {diagnostic}\n', False),
            (1, 'Fatal: unrelated failure\n', False),
            (1, f'{diagnostic}\n', False),
            (1, f'Fatal: unrelated failure\n\n{diagnostic}\n', False),
            (1, f'Fatal: unrelated failure\nother diagnostic\n{diagnostic}\n', False),
            (1, f'{diagnostic}\nFatal: unrelated failure\n', False),
            (1, f'Fatal: {diagnostic}\nFatal: another failure\n', False),
            (1, 'Fatal: D2H_STATUS_EARLY\n', False),
            (1, 'Fatal: D2H_STATUS_EARLY descriptor=0 enqueued=0 required=4\n', False),
            (1, 'Fatal: D2H_STATUS_EARLY descriptor=0 enqueued=x required=4 tx_write=0\n', False),
            (1, f'Fatal: {diagnostic}\nError-[SE] invalid\n', False),
            (1, f'Fatal: {diagnostic}\nError: other problem\n', False),
            (0, f'Error! Unknown INTENDED_DEVICE_FAMILY=Stratix V.\nFatal: {diagnostic}\n', False),
            (1, f'NATIVE_D2H_PACKETIZER_PASS\nFatal: {diagnostic}\n', False),
            (1, f'NATIVE_D2H_QUARANTINE_PASS\nFatal: {diagnostic}\n', False),
        ):
            with self.subTest(code=code, text=text):
                self.assertEqual(runner.passed_run(code, text, True), expected)

    def test_quarantine_uses_a_distinct_pass_marker(self):
        text = 'NATIVE_D2H_QUARANTINE_PASS partial_head=1\n'
        self.assertTrue(runner.passed_run(0, text, False, runner.QUARANTINE_PASS))
        self.assertFalse(runner.passed_run(0, text, False))
        self.assertFalse(runner.passed_run(
            0, 'NATIVE_D2H_PACKETIZER_PASS\n', False, runner.QUARANTINE_PASS))

    def test_suite_selection_does_not_relabel_witness_as_full(self):
        self.assertEqual(runner.SUITES['status-witness'],
                         ('status', 'D2H_STATUS_EARLY', True))
        self.assertEqual(runner.SUITES['status-corrected'],
                         ('status', runner.PASS, False))
        self.assertEqual(runner.SUITES['full'], ('matrix', runner.PASS, False))
        self.assertEqual(runner.SUITES['quarantine'],
                         ('quarantine', runner.QUARANTINE_PASS, False))

    def test_launcher_symlink_keeps_vcs_basename(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dispatch = root / 'dispatch'
            dispatch.write_text('#!/bin/sh\nexit 0\n')
            dispatch.chmod(0o700)
            vcs = root / 'vcs'
            vcs.symlink_to(dispatch)
            command = runner.command(str(vcs), 'VCS', False)
            self.assertEqual(command, [str(vcs)])
            self.assertNotEqual(command[0], str(dispatch))

    def test_missing_launcher_is_not_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = str(Path(directory) / 'vcs')
            with self.assertRaises(runner.UnavailableTool):
                runner.command(missing, 'VCS', False)
            self.assertEqual(runner.command(missing, 'VCS', True), [missing])

    def test_runner_rejects_bad_private_sha(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'not_vendor.sv'
            source.write_bytes(b'module synthetic; endmodule\n')
            for name, pin in runner.PINS.items():
                with self.subTest(name=name), self.assertRaises(ValueError):
                    runner.read_source(source, name, (pin,))
            with self.assertRaises(ValueError):
                runner.read_source(source, 'producer',
                                   (runner.PRODUCER_SHA, runner.CORRECTED_PRODUCER_SHA))

    def test_runner_rejects_missing_and_empty_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'source.sv'
            with self.assertRaises(ValueError):
                runner.read_source(source, 'source')
            source.touch()
            with self.assertRaises(ValueError):
                runner.read_source(source, 'source')

    def test_transforms_reject_formatted_or_synthetic_vendor_input(self):
        raw = b'assign WrDMADescDone_o = desc_completed;\n'
        with self.assertRaises(ValueError):
            builder.transform_tlpgen(raw)
        with self.assertRaises(ValueError):
            builder.transform_aligner(raw)

    def test_builder_and_runner_agree_on_original_pins(self):
        self.assertEqual(builder.TLPGEN_SHA, runner.PINS['tlpgen'])
        self.assertEqual(builder.ALIGNER_SHA, runner.PINS['aligner'])
        self.assertEqual(builder.WRAPPER_SHA, runner.PINS['wrapper'])

    def test_unique_span_preserves_other_synthetic_bytes(self):
        raw = b'prefix\r\n  old_anchor = 1;\r\nsuffix\n'
        result = builder.unique_sub(raw, rb'old_anchor\s*=\s*1;',
                                    b'new_anchor = 2;', 'synthetic span')
        self.assertEqual(result, b'prefix\r\n  new_anchor = 2;\r\nsuffix\n')

    def test_unique_span_refuses_absent_or_duplicate_anchor(self):
        for raw in (b'other;', b'old; old;'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                builder.unique_sub(raw, rb'old;', b'new;', 'synthetic span')


if __name__ == '__main__':
    unittest.main()
