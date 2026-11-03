"""Bind extraction to the real qualified CRA transform, not synthetic RTL."""
import copy
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from kernel_abi import extract, SNAPSHOT_RETIREMENT_SHA256
from cra_read_clear_safe import transform
from kernel_executor_codegen import render, validate
from prepare_corrected_kernel import prepare
import hashlib
import json


class CorrectedAbiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name)
        original = ROOT / 'qualification/kernel-system-vcs-v1/source'
        self.original_abi = extract(original)
        for relative in self.original_abi['source_sha256']:
            target = self.source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original / relative, target)
        for index in (1, 2):
            target = self.agent(index)
            target.write_text(transform(target.read_text(), index))

    def agent(self, index):
        name = f'Pass{index}Kernel'
        return self.source / f'kernel_hdl/{name}/{name}_function_cra_agent.sv'

    def test_exact_corrected_source_is_classified_and_embedded(self):
        abi = extract(self.source)
        validate(abi)
        self.assertTrue(all(k['completion_accounting'] == 'delayed_snapshot_v1'
                            for k in abi['kernels']))
        rendered = render(abi, False)
        self.assertEqual(rendered.count('CompletionAccounting::DelayedSnapshotV1'), 2)
        for digest in SNAPSHOT_RETIREMENT_SHA256.values():
            self.assertIn(digest, rendered)
        self.assertNotIn('read_clear_safe = true', rendered)

    def test_changed_arithmetic_is_rejected(self):
        target = self.agent(1)
        before = target.read_text()
        old = 'adder_counter_width_b - read_clear_safe_snapshot_q'
        self.assertEqual(before.count(old), 1)
        target.write_text(before.replace(old, 'adder_counter_width_b + read_clear_safe_snapshot_q'))
        with self.assertRaises(ValueError):
            extract(self.source)

    def test_corrected_label_cannot_upgrade_original_hashes(self):
        abi = copy.deepcopy(self.original_abi)
        for kernel in abi['kernels']:
            kernel['completion_accounting'] = 'delayed_snapshot_v1'
        with self.assertRaises(ValueError):
            validate(abi)
        rendered = render(self.original_abi, False)
        self.assertEqual(rendered.count('CompletionAccounting::Unqualified'), 2)

    def test_compile_and_host_inputs_select_identical_agents(self):
        out = self.source / 'prepared'
        prepare(ROOT, out)
        original_lines = (ROOT / 'qualification/kernel-system-vcs-v1/sources-23.1std.f').read_text().splitlines()
        lines = (out / 'sources.f').read_text().splitlines()
        self.assertEqual(len(lines), len(original_lines))
        self.assertEqual(sum(a != b for a, b in zip(lines, original_lines)), 2)
        abi = json.loads((out / 'abi.json').read_text())
        for name, digest in SNAPSHOT_RETIREMENT_SHA256.items():
            relative = f'kernel_hdl/{name}/{name}_function_cra_agent.sv'
            self.assertIn(str(out / 'candidate' / relative), lines)
            self.assertEqual(abi['source_sha256'][relative], digest)
            self.assertEqual(hashlib.sha256((out / 'abi-source' / relative).read_bytes()).hexdigest(), digest)
        before = (out / 'sources.f').read_bytes()
        with self.assertRaises(ValueError):
            prepare(ROOT, out)
        self.assertEqual((out / 'sources.f').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
