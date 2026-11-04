"""Exact vector completion accounting source bindings; no device admission."""
import copy
import hashlib
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from kernel_abi import extract, SNAPSHOT_RETIREMENT_SHA256
from kernel_executor_codegen import validate, render

class OpenClCraAbiTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source=Path(self.temp.name)
        original=ROOT/'qualification/opencl-stream-compile-v1/retrieved/streaming'
        self.original=extract(original,packed=True)
        overlay=ROOT/'qualification/opencl-cra-retirement-v1/corrected'
        for relative in self.original['source_sha256']:
            out=self.source/relative
            out.parent.mkdir(parents=True,exist_ok=True)
            source=overlay/out.name if out.name.endswith('_function_cra_agent.sv') else original/relative
            shutil.copyfile(source,out)

    def test_exact_vector_binding(self):
        abi=extract(self.source,packed=True)
        validate(abi)
        for kernel in abi['kernels']:
            self.assertEqual(kernel['completion_accounting'],'delayed_snapshot_v1')
            path=self.source/f"kernel_hdl/{kernel['name']}/{kernel['name']}_function_cra_agent.sv"
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),SNAPSHOT_RETIREMENT_SHA256[kernel['name']])
        self.assertEqual(render(abi,False).count('CompletionAccounting::DelayedSnapshotV1'),2)

    def test_original_cannot_claim_corrected_profile(self):
        self.assertTrue(all('completion_accounting' not in k for k in self.original['kernels']))
        bad=copy.deepcopy(self.original)
        for kernel in bad['kernels']:kernel['completion_accounting']='delayed_snapshot_v1'
        with self.assertRaises(ValueError):validate(bad)

    def test_changed_corrected_body_rejected(self):
        p=next(self.source.glob('kernel_hdl/*/*_function_cra_agent.sv'))
        text=p.read_text();old='adder_counter_width_b - read_clear_safe_snapshot_q'
        self.assertEqual(text.count(old),1)
        p.write_text(text.replace(old,'adder_counter_width_b + read_clear_safe_snapshot_q'))
        with self.assertRaises(ValueError):extract(self.source,packed=True)

if __name__=='__main__':unittest.main()
