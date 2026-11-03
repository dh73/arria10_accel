#!/usr/bin/env python3
"""Unit tests for c126_preflight.py.

The fixture is structurally C126-like but its synthetic non-key pin names are
not a board pinout and must never be used to generate a hardware image.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

import c126_preflight as tool


def indexed_ports() -> list[str]:
    result: list[str] = []
    for base, indices in tool.EXPECTED_INDEXED_PORTS.items():
        for index in sorted(indices):
            result.append(f"{base}[{index}]")
    assert len(result) == 136
    return result


def make_fixture(root: Path) -> Path:
    qii = root / "qii"
    (qii / "ip" / "ed_synth").mkdir(parents=True)

    used_pins = set(tool.EXPECTED_KEY_PINS.values())
    pin_counter = 0
    locations: list[str] = []
    for port in indexed_ports():
        pin = tool.EXPECTED_KEY_PINS.get(port)
        if pin is None:
            while True:
                candidate = f"PIN_TEST_{pin_counter:03d}"
                pin_counter += 1
                if candidate not in used_pins:
                    pin = candidate
                    break
        used_pins.add(pin)
        locations.append(f"set_location_assignment {pin} -to {port}")

    qsf = "\n".join(
        [
            "set_global_assignment -name TOP_LEVEL_ENTITY ed_synth_top",
            "set_global_assignment -name FAMILY {Arria 10}",
            "set_global_assignment -name DEVICE 10AX115S3F45E2SGE3",
            "set_global_assignment -name QSYS_FILE ed_synth.qsys",
            "set_global_assignment -name IP_FILE ip/ed_synth/ed_synth_emif.ip",
            "set_global_assignment -name IP_FILE ip/ed_synth/ed_synth_global_reset_n_splitter.ip",
            "set_global_assignment -name IP_FILE ip/ed_synth/ed_synth_tg.ip",
            "set_global_assignment -name SDC_FILE jtag_example.sdc",
            "set_global_assignment -name SYSTEMVERILOG_FILE ed_synth_top.sv",
            "set_global_assignment -name EDA_EXDES_CUSTOM_SIM_SCRIPT_VCS ../sim/vcs_setup.sh -section_id eda_simulation",
            "set_global_assignment -name DEVICE_IO_STANDARD_ALL {1.2 V}",
            *locations,
            "",
        ]
    )
    (qii / "ed_synth.qsf").write_text(qsf, encoding="utf-8")
    (qii / "ed_synth.qpf").write_text('PROJECT_REVISION = "ed_synth"\n', encoding="utf-8")
    (qii / "ed_synth.qsys").write_text("<system name='fixture'/>\n", encoding="utf-8")
    (qii / "ip" / "ed_synth" / "ed_synth_emif.ip").write_text("<ip/>\n", encoding="utf-8")
    (qii / "ip" / "ed_synth" / "ed_synth_global_reset_n_splitter.ip").write_text("<ip/>\n", encoding="utf-8")
    (qii / "ip" / "ed_synth" / "ed_synth_tg.ip").write_text("<ip/>\n", encoding="utf-8")
    (qii / "jtag_example.sdc").write_text(
        "# synthetic fixture only\ncreate_clock -name altera_reserved_tck -period 30 [get_ports altera_reserved_tck]\n",
        encoding="utf-8",
    )

    declarations: list[str] = []
    for base, indices in tool.EXPECTED_INDEXED_PORTS.items():
        width = max(indices) + 1
        direction = "output"
        if base in {
            "emif_mem_mem_alert_n",
            "emif_oct_oct_rzqin",
            "emif_pll_ref_clk_clk",
            "global_reset_reset_n",
        }:
            direction = "input"
        elif base in {"emif_mem_mem_dbi_n", "emif_mem_mem_dq", "emif_mem_mem_dqs", "emif_mem_mem_dqs_n"}:
            direction = "inout"
        declarations.append(f"  {direction} wire [{width - 1}:0] {base}")
    top = ["module ed_synth_top (", ",\n".join(declarations), ");"]
    for status in tool.STATUS_PORTS:
        top.append(f"wire inv_{status};")
        top.append(f"assign {status} = ~inv_{status};")
    top.append("endmodule")
    (qii / "ed_synth_top.sv").write_text("\n".join(top) + "\n", encoding="utf-8")
    return qii


class C126PreflightTests(unittest.TestCase):
    def test_preflight_snapshots_without_mutating_peer_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = make_fixture(root)
            before = tool.manifest(source)
            output = root / "result"
            snapshot, report, issues = tool.create_snapshot_run(
                source,
                output,
                project="ed_synth",
                expected_top=tool.DEFAULT_TOP,
                expected_device=tool.DEFAULT_DEVICE,
                enforce_known_hashes=False,
                strict_c126_pin_schema=True,
            )
            self.assertTrue(report["source_consistent"])
            self.assertFalse(report["physical_ready"])
            self.assertEqual(report["location_assignment_count"], 136)
            self.assertTrue(snapshot.is_dir())
            self.assertEqual(before, tool.manifest(source))
            self.assertEqual(before, tool.manifest(snapshot))
            self.assertFalse(any(issue.severity == "ERROR" for issue in issues))
            stored = json.loads((output / "preflight.json").read_text(encoding="utf-8"))
            self.assertFalse(stored["physical_ready"])

    def test_missing_reference_is_a_fatal_source_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = make_fixture(root)
            (source / "ip" / "ed_synth" / "ed_synth_tg.ip").unlink()
            _, report, issues = tool.create_snapshot_run(
                source,
                root / "result",
                project="ed_synth",
                expected_top=tool.DEFAULT_TOP,
                expected_device=tool.DEFAULT_DEVICE,
                enforce_known_hashes=False,
                strict_c126_pin_schema=True,
            )
            self.assertFalse(report["source_consistent"])
            self.assertIn("MISSING_REFERENCE", {issue.code for issue in issues})

    def test_duplicate_physical_pin_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = make_fixture(root)
            qsf = source / "ed_synth.qsf"
            text = qsf.read_text(encoding="utf-8")
            text = text.replace("PIN_TEST_001", "PIN_TEST_000", 1)
            qsf.write_text(text, encoding="utf-8")
            _, report, issues = tool.create_snapshot_run(
                source,
                root / "result",
                project="ed_synth",
                expected_top=tool.DEFAULT_TOP,
                expected_device=tool.DEFAULT_DEVICE,
                enforce_known_hashes=False,
                strict_c126_pin_schema=True,
            )
            self.assertFalse(report["source_consistent"])
            self.assertIn("DUPLICATE_PHYSICAL_PIN", {issue.code for issue in issues})

    def test_reference_escape_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = make_fixture(root)
            qsf = source / "ed_synth.qsf"
            qsf.write_text(
                qsf.read_text(encoding="utf-8")
                + "set_global_assignment -name IP_FILE ../outside.ip\n",
                encoding="utf-8",
            )
            _, report, issues = tool.create_snapshot_run(
                source,
                root / "result",
                project="ed_synth",
                expected_top=tool.DEFAULT_TOP,
                expected_device=tool.DEFAULT_DEVICE,
                enforce_known_hashes=False,
                strict_c126_pin_schema=True,
            )
            self.assertFalse(report["source_consistent"])
            self.assertIn("REFERENCE_ESCAPES_SOURCE", {issue.code for issue in issues})

    def test_symlink_is_rejected_before_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = make_fixture(root)
            outside = root / "outside.txt"
            outside.write_text("outside\n", encoding="utf-8")
            (source / "escape-link").symlink_to(outside)
            with self.assertRaises(tool.PreflightError):
                tool.create_snapshot_run(
                    source,
                    root / "result",
                    project="ed_synth",
                    expected_top=tool.DEFAULT_TOP,
                    expected_device=tool.DEFAULT_DEVICE,
                    enforce_known_hashes=False,
                    strict_c126_pin_schema=True,
                )

    def test_output_may_not_be_inside_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source = make_fixture(Path(temp))
            with self.assertRaises(tool.PreflightError):
                tool.require_disjoint_source_output(source, source / "out")

    def test_build_command_runs_only_in_snapshot_and_without_shell(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = make_fixture(root)
            source_before = tool.manifest(source)
            output = root / "result"
            snapshot, report, issues = tool.create_snapshot_run(
                source,
                output,
                project="ed_synth",
                expected_top=tool.DEFAULT_TOP,
                expected_device=tool.DEFAULT_DEVICE,
                enforce_known_hashes=False,
                strict_c126_pin_schema=True,
            )
            self.assertTrue(report["source_consistent"])
            self.assertFalse(any(issue.severity == "ERROR" for issue in issues))

            fake_log = root / "fake-quartus.json"
            fake = root / "quartus_sh"
            fake.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys\n"
                "pathlib.Path('output_files').mkdir(exist_ok=True)\n"
                "pathlib.Path('output_files/ed_synth.sof').write_bytes(b'fixture')\n"
                "pathlib.Path(os.environ['FAKE_QUARTUS_LOG']).write_text(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd()}))\n"
                "print('fake Quartus compile')\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            environment = dict(os.environ)
            environment["FAKE_QUARTUS_LOG"] = str(fake_log)
            rc = tool.run_quartus_compile(
                snapshot,
                output,
                project="ed_synth",
                quartus_sh=str(fake),
                environment=environment,
            )
            self.assertEqual(rc, 2)  # Native success without STA is not closure.
            result = json.loads((output / 'build-result.json').read_text())
            self.assertEqual(result['exit_code'], 0)
            self.assertEqual(result['design_closure']['state'], 'unknown')
            invocation = json.loads(fake_log.read_text(encoding="utf-8"))
            self.assertEqual(invocation["argv"], ["--flow", "compile", "ed_synth"])
            self.assertEqual(Path(invocation["cwd"]), snapshot)
            self.assertTrue((snapshot / "output_files" / "ed_synth.sof").is_file())
            self.assertFalse((source / "output_files").exists())
            self.assertEqual(source_before, tool.manifest(source))

    def test_project_name_cannot_escape_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = make_fixture(root)
            for project in ('../ed_synth', '/tmp/ed_synth', 'nested/ed_synth'):
                with self.subTest(project=project):
                    with self.assertRaises(tool.PreflightError):
                        tool.find_project_files(source, project)

    def test_cli_build_requires_explicit_acknowledgement(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = make_fixture(root)
            rc = tool.main(
                [
                    "build",
                    "--source",
                    str(source),
                    "--output",
                    str(root / "result"),
                    "--skip-known-hashes",
                ]
            )
            self.assertEqual(rc, 64)
            self.assertFalse((root / "result").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
