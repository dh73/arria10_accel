#!/usr/bin/env python3
"""Python-only checks of source refusal and strict native diagnostic parsing.

The strings below test the parser. They are not simulator output, an RTL run,
or proof evidence. Run VCS and Lean separately through run.py on actual tools.
"""
from pathlib import Path
import tempfile
import unittest

import run


class NativeDiagnostics(unittest.TestCase):
    def setUp(self):
        self.witness = "D2H_ORIGINAL_STATUS_CAPACITY"
        self.native = ('Fatal: "d2h_composition_tb.sv", 91: d2h_composition_tb: at time 100\n'
                       'D2H_ORIGINAL_STATUS_CAPACITY count=128\n')
        self.success = "D2H_COMPOSITION_PASS case=stress descriptors=6672\n"

    def test_zero_after_native_fatal_is_witness(self):
        self.assertTrue(run.passed_run(0, self.native, "capacity-witness", self.witness))

    def test_nonzero_without_native_fatal_is_not_witness(self):
        self.assertFalse(run.passed_run(1, "compile failed\n", "capacity-witness", self.witness))

    def test_signal_or_timeout_is_not_witness(self):
        for code in (-9, 124, 137):
            with self.subTest(code=code):
                self.assertFalse(run.passed_run(code, self.native, "capacity-witness", self.witness))

    def test_unique_fatal_token_on_header(self):
        text = 'Fatal: "fixture.sv": D2H_ORIGINAL_STATUS_CAPACITY count=128\n'
        self.assertTrue(run.passed_run(1, text, "capacity-witness", self.witness))

    def test_token_without_native_fatal_rejected(self):
        self.assertFalse(run.passed_run(0, self.witness + " count=128\n", "capacity-witness", self.witness))

    def test_token_outside_native_fatal_block_rejected(self):
        text = self.witness + " count=128\nFatal: fixture\nanother defect\n"
        self.assertFalse(run.passed_run(0, text, "capacity-witness", self.witness))

    def test_second_fatal_rejected(self):
        self.assertFalse(run.passed_run(0, self.native + "Fatal: other\n", "capacity-witness", self.witness))

    def test_duplicate_expected_token_rejected(self):
        self.assertFalse(run.passed_run(0, self.native + self.witness + "\n", "capacity-witness", self.witness))

    def test_capacity_diagnostic_requires_full_count(self):
        for text in (self.native.replace("count=128", "count=127"),
                     self.native.replace("count=128", "count=1280"),
                     self.native.replace(" count=128", "")):
            with self.subTest(text=text):
                self.assertFalse(run.passed_run(0, text, "capacity-witness", self.witness))

    def test_failure_and_base_diagnostic_fields(self):
        success = "Fatal: fixture\nD2H_ORIGINAL_FALSE_SUCCESS data=00000001\n"
        retarget = "Fatal: fixture\nD2H_ORIGINAL_BASE_RETARGET address=0000001234569024\n"
        self.assertTrue(run.passed_run(0, success, "failure-witness", "D2H_ORIGINAL_FALSE_SUCCESS"))
        self.assertTrue(run.passed_run(0, retarget, "base-witness", "D2H_ORIGINAL_BASE_RETARGET"))
        self.assertFalse(run.passed_run(0, success.replace("00000001", "00000000"),
                                        "failure-witness", "D2H_ORIGINAL_FALSE_SUCCESS"))
        self.assertFalse(run.passed_run(0, retarget.replace("0000001234569024", "1234"),
                                        "base-witness", "D2H_ORIGINAL_BASE_RETARGET"))
        self.assertFalse(run.passed_run(0, retarget.replace("0000001234569024", "00000012345690240"),
                                        "base-witness", "D2H_ORIGINAL_BASE_RETARGET"))

    def test_all_model_error_spellings_rejected(self):
        for error in ("Error! unsupported Stratix V", "Error: invalid model", "Error-[SE] bad source",
                      "UVM_FATAL bad", "UVM_ERROR bad", "assertion failed", "Segmentation fault"):
            with self.subTest(error=error):
                self.assertFalse(run.passed_run(0, self.native + error, "capacity-witness", self.witness))
                self.assertFalse(run.passed_run(0, self.success + error, "stress"))
                self.assertFalse(run.passed_compile(0, error, True))

    def test_success_is_exact_case_and_unique(self):
        self.assertTrue(run.passed_run(0, self.success, "stress"))
        self.assertFalse(run.passed_run(0, self.success, "reset"))
        self.assertFalse(run.passed_run(0, self.success + self.success, "stress"))
        self.assertFalse(run.passed_run(1, self.success, "stress"))
        self.assertFalse(run.passed_run(0, "echo " + self.success, "stress"))

    def test_witness_and_success_cannot_both_pass(self):
        self.assertFalse(run.passed_run(0, self.native + self.success, "capacity-witness", self.witness))
        self.assertFalse(run.passed_run(0, self.native + self.success, "stress"))

    def test_compile_requires_clean_log_zero_exit_and_binary(self):
        self.assertTrue(run.passed_compile(0, "Compilation complete\n", True))
        self.assertFalse(run.passed_compile(0, "Compilation complete\n", False))
        self.assertFalse(run.passed_compile(1, "Compilation complete\n", True))
        self.assertFalse(run.passed_compile(0, self.native, True))


class SourceIdentity(unittest.TestCase):
    def test_all_fetched_owned_sources_match_exact_pins(self):
        for relative, pin in run.OWNED_PINS.items():
            with self.subTest(path=relative):
                run.read_source(run.REPO / relative, relative, (pin,))

    def test_frozen_bench_byte_mutation_rejected(self):
        relative = "experiments/dma-status-v3/tests/native_d2h_packetizer_tb.sv"
        raw = (run.REPO / relative).read_bytes()
        pin = run.OWNED_PINS[relative]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bench.sv"
            for changed in (raw + b"\n", raw.replace(b"\n", b"\r\n"), raw[:-1] + b" "):
                path.write_bytes(changed)
                with self.assertRaises(ValueError):
                    run.read_source(path, "mutated frozen bench", (pin,))

    def test_bench_derivative_preserves_complete_packet_oracle(self):
        builder = run.load_builder()
        source = (run.REPO / "experiments/dma-status-v3/tests/native_d2h_packetizer_tb.sv").read_bytes()
        derived = builder.build_bench(source)

        def oracle(raw):
            first = b"  task automatic accept_packet_word("
            last = b"\n  endtask\n"
            self.assertEqual(raw.count(first), 1)
            start = raw.index(first)
            end = raw.index(last, start) + len(last)
            return raw[start:end]

        self.assertEqual(oracle(derived), oracle(source))
        self.assertIn(b"module d2h_composition_tb;", derived)
        self.assertNotIn(b"tx_fifo.size()", derived)

    def test_bench_transform_refuses_changed_original(self):
        builder = run.load_builder()
        source = (run.REPO / "experiments/dma-status-v3/tests/native_d2h_packetizer_tb.sv").read_bytes()
        for changed in (source + b"\n", source.replace(b"\n", b"\r\n"),
                        source.replace(b"D2H_STATUS_EARLY", b"D2H_STATUS_LATER")):
            with self.subTest(sha256=run.sha(changed)), self.assertRaises(ValueError):
                builder.build_bench(changed)

    def test_tx_transform_checks_exact_bytes_in_both_variants(self):
        builder = run.load_builder()
        source = (run.REPO / "experiments/dma-fetch-v4/rtl/controller_tx_v4.svh").read_bytes()
        self.assertEqual(builder.build_tx(source, original=True), source)
        self.assertIsInstance(builder.build_tx(source), bytes)
        for original in (False, True):
            for changed in (source + b"\n", source.replace(b"\n", b"\r\n"), source[:-1]):
                with self.subTest(original=original, sha256=run.sha(changed)), self.assertRaises(ValueError):
                    builder.build_tx(changed, original=original)


if __name__ == "__main__":
    unittest.main()
