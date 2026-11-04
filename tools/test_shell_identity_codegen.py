"""Generation tests use synthetic extractor inputs, never an FPGA image."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import kernel_executor_codegen as abi_codegen
import shell_identity_codegen as identity
from test_kernel_executor_codegen import ROOT, SNAPSHOT, fixture


class IdentityCodegenTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.source = self.work / "kernel"
        self.source.mkdir()
        fixture(self.source, json.loads(SNAPSHOT.read_text()))
        self.root = self.work / "build-inputs"
        (self.root / "rtl").mkdir(parents=True)
        (self.root / identity.AUTO_INPUT).write_bytes(
            (ROOT / identity.AUTO_INPUT).read_bytes())
        (self.root / "build.qsf").write_text("# explicit test recipe input\n")
        self.plan = {"schema": 1, "management": {"space": 7, "offset": 0},
                     "cra": {"space": 7, "offset": 256},
                     "resources": [{"space": 7, "bytes": 4096}],
                     "inputs": ["build.qsf"], "recipe": "synthetic-extractor-test"}
        self.plan_path = self.work / "plan.json"
        self.out = self.work / "prepared"

    def prepare(self, out=None):
        self.plan_path.write_bytes(identity.encoded(self.plan))
        return identity.prepare(self.source, self.plan_path, self.root, out or self.out)

    def test_deterministic_actual_extraction_and_endianness(self):
        first = self.prepare()
        other = self.work / "second"
        second = self.prepare(other)
        self.assertEqual(first, second)
        for name in ("prepared.json", "shell_identity_params.svh", "shell_identity_expected.hpp"):
            self.assertEqual((self.out / name).read_bytes(), (other / name).read_bytes())
        actual = identity.kernel_abi.extract(self.source)
        self.assertEqual(first["source_sha256"], abi_codegen.source_contract_sha256(actual))
        sv = (self.out / "shell_identity_params.svh").read_text()
        self.assertIn("256'h" + bytes.fromhex(first["source_sha256"])[::-1].hex(), sv)
        (self.source / "kernel_system.sv").write_text(
            (self.source / "kernel_system.sv").read_text() + "// changed source bytes\n")
        changed = self.prepare(self.work / "changed")
        self.assertNotEqual(first["source_sha256"], changed["source_sha256"])
        self.assertNotEqual(first["build_sha256"], changed["build_sha256"])

    def test_source_identity_rejects_unknown_metadata(self):
        source = json.loads(SNAPSHOT.read_text())
        normalized = abi_codegen.source_contract(source)
        self.assertEqual(abi_codegen.source_contract_sha256(source),
                         abi_codegen.source_contract_sha256(normalized))
        reversed_kernels = copy.deepcopy(source)
        reversed_kernels["kernels"].reverse()
        self.assertEqual(abi_codegen.source_contract_sha256(source),
                         abi_codegen.source_contract_sha256(reversed_kernels))
        for edit in (lambda a: a.update(unknown=1),
                     lambda a: a["kernels"][0].update(unknown=1),
                     lambda a: a["kernels"][0]["arguments"][0].update(unknown=1)):
            bad = copy.deepcopy(source)
            edit(bad)
            with self.assertRaises(ValueError):
                abi_codegen.source_contract_sha256(bad)

    def test_retained_packed_source_identity(self):
        source = ROOT / 'qualification/sycl-stream-masked-host-abi-v1/source'
        if not source.is_dir():
            self.skipTest('retained compiler sources are not public fixtures')
        self.plan_path.write_bytes(identity.encoded(self.plan))
        with self.assertRaises(ValueError):
            identity.prepare(source, self.plan_path, self.root, self.out)
        self.assertFalse(self.out.exists())
        actual = identity.kernel_abi.extract(source, packed=True)
        manifest = identity.prepare(source, self.plan_path, self.root, self.out,
                                    packed=True)
        self.assertEqual(manifest['abi']['schema'], 2)
        self.assertEqual(manifest['source_sha256'],
                         abi_codegen.source_contract_sha256(actual))
        self.assertEqual(identity.load_prepared(self.out), manifest)
        self.assertEqual([a['alignment_bytes'] for a in
                          actual['kernels'][0]['arguments']], [1, 64, 64])
        bad = copy.deepcopy(actual)
        del bad['kernels'][0]['arguments'][0]['alignment_bytes']
        with self.assertRaises(ValueError):
            abi_codegen.source_contract_sha256(bad)

    def test_shapes_ranges_paths_and_no_partial_publication(self):
        mutations = [
            lambda p: p.update(schema=True),
            lambda p: p.update(unrecognized=1),
            lambda p: p["resources"].append(dict(p["resources"][0])),
            lambda p: p["resources"][0].update(bytes=0),
            lambda p: p["management"].update(offset=1),
            lambda p: p["cra"].update(offset=252),
            lambda p: p["cra"].update(offset=128),
            lambda p: p["cra"].update(space=99),
            lambda p: p["cra"].update(offset=4096),
            lambda p: p["cra"].update(offset=(1 << 64) - 8),
            lambda p: (p["resources"][0].update(bytes=(1 << 64) - 1),
                       p["cra"].update(offset=(1 << 64) - 8)),
            lambda p: p["resources"][0].update(bytes=1 << 64),
            lambda p: p["cra"].update(space=True),
            lambda p: p.update(inputs=["build.qsf", "build.qsf"]),
            lambda p: p.update(inputs=["../escape"]),
            lambda p: p.update(inputs=["./build.qsf"]),
            lambda p: p.update(inputs=["/absolute"]),
            lambda p: p.update(inputs=[]),
        ]
        original = copy.deepcopy(self.plan)
        for mutation in mutations:
            self.plan = copy.deepcopy(original)
            mutation(self.plan)
            with self.subTest(plan=self.plan), self.assertRaises(ValueError):
                self.prepare()
            self.assertFalse(self.out.exists())

    def test_duplicate_nonfinite_and_symlink_escape(self):
        for text in ('{"schema":1,"schema":1}', '{"schema":NaN}', '{"schema":Infinity}'):
            self.plan_path.write_text(text)
            with self.assertRaises(ValueError):
                identity.read_json(self.plan_path)
        outside = self.work / "outside"
        outside.write_text("not an input within root\n")
        (self.root / "escape").symlink_to(outside)
        self.plan["inputs"] = ["escape"]
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.out.exists())

    def test_unsupported_source_and_output_preservation(self):
        self.out.mkdir()
        sentinel = self.out / "retained"
        sentinel.write_text("unchanged\n")
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(sentinel.read_text(), "unchanged\n")
        agent = self.source / "kernel_hdl/Pass1Kernel/Pass1Kernel_function_cra_agent.sv"
        agent.write_text(agent.read_text().replace(
            "reg [1:0] finish_counter", "reg [2:0] finish_counter"))
        target = self.work / "invalid-source"
        with self.assertRaises(ValueError):
            self.prepare(target)
        self.assertFalse(target.exists())

    def test_output_association_rejects_false_claims_and_altered_bytes(self):
        self.prepare()
        bitstream = self.work / "fixture.rbf"
        # Arbitrary test data, not a synthesized or loadable FPGA image.
        bitstream.write_bytes(bytes(range(256)) + b"fixture only")
        record_path = self.work / "output.json"
        record = identity.bind(self.out, bitstream, record_path)
        self.assertEqual(identity.check(self.out, bitstream, record_path), record)
        self.assertEqual(record["bitstream_sha256"],
                         hashlib.sha256(bitstream.read_bytes()).hexdigest())
        self.assertEqual(record["bitstream_bytes"], bitstream.stat().st_size)
        original = record_path.read_bytes()
        for key in ("source_sha256", "build_sha256", "prepared_sha256", "bitstream_sha256"):
            bad = dict(record)
            bad[key] = "0" * 64
            record_path.write_bytes(identity.encoded(bad))
            with self.subTest(key=key), self.assertRaises(ValueError):
                identity.check(self.out, bitstream, record_path)
        record_path.write_bytes(original)
        bitstream.write_bytes(bitstream.read_bytes() + b"x")
        with self.assertRaises(ValueError):
            identity.check(self.out, bitstream, record_path)
        with self.assertRaises(FileExistsError):
            identity.bind(self.out, bitstream, record_path)
        self.assertEqual(record_path.read_bytes(), original)

    def test_tampered_prepared_source_and_rom_rejected(self):
        self.prepare()
        path = self.out / "prepared.json"
        original = path.read_bytes()
        manifest = identity.read_json(path)
        manifest["source_sha256"] = "0" * 64
        path.write_bytes(identity.encoded(manifest))
        with self.assertRaises(ValueError):
            identity.load_prepared(self.out)
        path.write_bytes(original)
        rom = self.out / "shell_identity_params.svh"
        rom.write_bytes(rom.read_bytes() + b"// edited\n")
        with self.assertRaises(ValueError):
            identity.load_prepared(self.out)


if __name__ == "__main__":
    unittest.main()
