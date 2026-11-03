#!/usr/bin/env python3
"""Local transport/SDC scope/checker controls. These are NOT native STA or RTL tests."""
import json
from pathlib import Path
import tempfile
import unittest

import assess
import run


class ComparatorControls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.expected = [assess.SOFT] + [f"hard_endpoint_{i}" for i in range(21)]
        self.baseline = {"reset_endpoints": [{"to": e} for e in self.expected],
                         "unconstrained_output_pairs": 5}
        (self.root / "native.complete").write_text("candidate\n")
        (self.root / "corners.json").write_text('[{"name":"fixture","hold_only":0}]')
        self.old = [(assess.RESET, e, "", "ref") for e in self.expected]
        self.old += [(f"led_driver_{i}", p, "core", "") for i, p in enumerate(sorted(assess.STATUS))]
        self.old += [("unrelated_input", "unrelated_sink", "", "other")]
        self.new = [p for p in self.old if p[1] != assess.SOFT and p[1] not in assess.STATUS]
        for phase, pairs in (("before", self.old), ("after", self.new)):
            directory = self.root / phase / "corner_0"
            directory.mkdir(parents=True)
            self.write_ucp(directory, pairs)
            (directory / "clocks.json").write_text('{"active":["ref"]}')
            for kind in ("setup", "hold", "recovery", "removal"):
                self.write_rows(directory / f"internal_{kind}.jsonl",
                                [[kind, "r0", "r1", "ref", "ref", "0.25", "10"]])
                if kind in {"setup", "hold"}:
                    for stage in (0, 1):
                        self.write_rows(directory / f"chain_dreg[{stage}]_{kind}.jsonl",
                                        [[kind, "s0", "s1", "ref", "ref", "0.50", "10"]])
            self.write_rows(directory / "ddr.jsonl", [
                {"panel":"||Memory", "row":0, "cells":["Check", "Slack"]},
                {"panel":"||Memory", "row":1, "cells":["Write setup", "0.123"]},
                {"panel":"||Memory", "row":2, "cells":["Read hold", "0.456"]}])

    def write_rows(self, path, rows):
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))

    def write_ucp(self, directory, pairs):
        rows = [{"panel":"||Pairs", "row":0, "cells":["From", "To", "From Clock", "To Clock"]}]
        rows += [{"panel":"||Pairs", "row":i+1, "cells":list(p)} for i, p in enumerate(pairs)]
        self.write_rows(directory / "ucp.jsonl", rows)

    def check(self):
        return assess.assess(self.root, self.baseline, "candidate", True)

    def test_exact_partial_delta(self):
        result = self.check()
        self.assertTrue(result["partial_candidate_checked"])
        self.assertFalse(result["closure_pass"])
        self.assertEqual(len(result["remaining_reset_endpoints"]), 21)

    def test_forbidden_hard_endpoint_removal(self):
        self.write_ucp(self.root / "after/corner_0", self.new[1:])
        with self.assertRaisesRegex(RuntimeError, "Unexpected"):
            self.check()

    def test_new_unconstrained_path(self):
        self.write_ucp(self.root / "after/corner_0", self.new + [("new", "sink", "", "")])
        with self.assertRaisesRegex(RuntimeError, "Unexpected"):
            self.check()

    def test_empty_recovery_and_removal_rejected_even_when_equal(self):
        for phase in ("before", "after"):
            (self.root / phase / "corner_0/internal_recovery.jsonl").write_text("")
        with self.assertRaisesRegex(RuntimeError, "empty is not"):
            self.check()

    def test_missing_later_stage_hold(self):
        (self.root / "after/corner_0/chain_dreg[1]_hold.jsonl").unlink()
        with self.assertRaisesRegex(RuntimeError, "matrix"):
            self.check()

    def test_negative_ddr_check(self):
        path = self.root / "after/corner_0/ddr.jsonl"
        path.write_text(path.read_text().replace("0.456", "-0.001"))
        with self.assertRaisesRegex(RuntimeError, "DDR timing failure"):
            self.check()

    def test_nan_ddr_check(self):
        path = self.root / "after/corner_0/ddr.jsonl"
        path.write_text(path.read_text().replace("0.456", "NaN"))
        with self.assertRaisesRegex(RuntimeError, "NaN"):
            self.check()


class DdrBudgetControls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'ddr.jsonl'

    def check(self, rows):
        records = [{"panel": "DQS Gating", "row": i, "cells": row}
                   for i, row in enumerate(rows)]
        self.path.write_text("".join(json.dumps(row) + "\n" for row in records))
        return assess.ddr(self.path)

    def test_signed_component_with_positive_final_margin(self):
        self.check([["Operation", "Margin"], ["Memory Calibration", "-0.132"],
                    ["Final DQS Gating Margin", "1.229"]])

    def test_negative_final_margin_refused(self):
        with self.assertRaisesRegex(RuntimeError, "DDR timing failure"):
            self.check([["Operation", "Margin"], ["Final DQS Gating Margin", "-0.001"]])

    def test_missing_or_duplicate_final_margin_refused(self):
        for finals in ([], [["Final DQS Gating Margin", "1.229"]] * 2):
            with self.assertRaisesRegex(RuntimeError, "exactly one final"):
                self.check([["Operation", "Margin"], ["Memory Calibration", "-0.132"]] + finals)

    def test_non_numeric_budget_component_refused(self):
        with self.assertRaisesRegex(RuntimeError, "Unknown DDR slack encoding"):
            self.check([["Operation", "Margin"], ["Memory Calibration", "unknown"],
                        ["Final DQS Gating Margin", "1.229"]])


class RetainedSdcControls(unittest.TestCase):
    def setUp(self):
        import tkinter
        self.t = tkinter.Tcl()
        self.t.call('source', str(Path(__file__).with_name('path_guard.tcl')))
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name) / 'baseline'
        self.copy = Path(self.temp.name) / 'copy'
        for root in (self.base, self.copy):
            (root / 'qdb').mkdir(parents=True)
            (root / 'qdb/default.sdc').write_bytes(b'create_clock -period 10 [get_ports clk]\n')
        self.source = self.base / 'qdb/default.sdc'

    def check(self, path=None):
        return str(self.t.call('::c126::check_default_sdc', str(path or self.source),
                               str(self.copy), str(self.base)))

    def test_byte_identical_retained_generated_constraint(self):
        self.assertEqual(self.check(), str(self.copy / 'qdb/default.sdc'))

    def test_changed_constraint_refused(self):
        (self.copy / 'qdb/default.sdc').write_text('changed')
        with self.assertRaisesRegex(Exception, 'content differs'): self.check()

    def test_missing_counterpart_refused(self):
        (self.copy / 'qdb/default.sdc').unlink()
        with self.assertRaisesRegex(Exception, 'counterpart'): self.check()

    def test_prefix_collision_and_external_file_refused(self):
        for path in (str(self.base) + '-other/qdb/default.sdc',
                     self.base / 'other.sdc', self.base / 'qdb/tool.py'):
            with self.assertRaisesRegex(Exception, 'outside'): self.check(path)

    def test_local_constraint_keeps_original_path(self):
        path = self.copy / 'qdb/default.sdc'
        self.assertEqual(self.check(path), str(path))


class TclControls(unittest.TestCase):
    def setUp(self):
        try:
            import tkinter
        except ImportError:
            self.skipTest("tkinter Tcl interpreter not available; native Quartus still required")
        self.t = tkinter.Tcl()
        self.cuts = []
        self.bad = ""
        self.names = {"R": assess.RESET, "F": assess.SOFT, "D": assess.SOFT + "|d", "P":"issp_producer"}
        self.names.update({f"L{i}": p for i, p in enumerate(sorted(assess.STATUS))})
        self.t.eval('proc foreach_in_collection {v c body} {upvar 1 $v item; foreach item $c {uplevel 1 $body}}')
        self.t.createcommand("get_collection_size", lambda c: len(self.t.splitlist(c)))
        self.t.createcommand("get_ports", self.ports)
        self.t.createcommand("get_registers", lambda *a: ("F", "Fdup") if self.bad == "duplicate" else ("F",))
        self.t.createcommand("get_pins", lambda *a: ("D",))
        self.t.createcommand("get_node_info", self.node)
        self.t.createcommand("get_port_info", lambda option, obj: int((obj == "R") == (option == "-is_input_port")))
        self.t.createcommand("get_pin_info", lambda option, obj: self.names[obj] if option == "-name" else int(option == "-is_in_pin"))
        self.t.createcommand("get_edge_info", self.edge)
        self.t.createcommand("get_fanins", lambda *a: ("R", "P"))
        self.t.createcommand("set_false_path", lambda *a: self.cuts.append(a) or "")
        self.t.createcommand("post_message", lambda *a: "")
        self.t.eval("namespace eval ::c126 {}")
        for key, value in (("packet_verified", 1), ("status_observation_only", 1), ("soft", assess.SOFT)):
            self.t.setvar("::c126::" + key, value)
        self.t.setvar("::c126::status_ports", tuple(sorted(assess.STATUS)))

    def ports(self, pattern):
        name, = self.t.splitlist(pattern)
        result = tuple(k for k, n in self.names.items() if n == name)
        return result + ("Ldup",) if self.bad == "led_duplicate" and name in assess.STATUS else result

    def node(self, option, obj):
        if option == "-name": return self.names[obj]
        if option == "-type": return "reg" if obj == "F" else "port"
        return ("E",) if option == "-synch_edges" else ()

    def edge(self, option, obj):
        return {"-src":"D", "-dst":"F", "-type":"asynchronous" if self.bad == "async" else "synchronous",
                "-is_disabled":0}[option]

    def source(self):
        self.t.call("source", str(Path(__file__).with_name("candidate.sdc")))

    def test_only_six_scoped_exceptions(self):
        self.source()
        self.assertEqual(self.cuts[0], ("-from", "R", "-through", "D", "-to", "F"))
        self.assertEqual({c[1] for c in self.cuts[1:]}, {f"L{i}" for i in range(5)})
        self.assertEqual(len(self.cuts), 6)

    def test_duplicate_first_stage_rejected_before_cut(self):
        self.bad = "duplicate"
        with self.assertRaises(Exception): self.source()
        self.assertEqual(self.cuts, [])

    def test_default_soft_only(self):
        self.t.setvar("::c126::status_observation_only", 0)
        self.source()
        self.assertEqual(self.cuts, [("-from", "R", "-through", "D", "-to", "F")])

    def test_async_pin_rejected_before_cut(self):
        self.bad = "async"
        with self.assertRaises(Exception): self.source()
        self.assertEqual(self.cuts, [])

    def test_duplicate_led_rejected_before_cut(self):
        self.bad = "led_duplicate"
        with self.assertRaises(Exception): self.source()
        self.assertEqual(self.cuts, [])

    def test_tcl_argument_quoting(self):
        value = 'a[0] $HOME "quoted" \\ {x}\nnext'
        self.t.eval("set value " + run.tcl_word(value))
        self.assertEqual(self.t.getvar("value"), value)


class NativeCollectionControls(unittest.TestCase):
    def setUp(self):
        import tkinter
        self.t = tkinter.Tcl()
        self.t.call('source', str(Path(__file__).with_name('diag.tcl')))
        self.t.eval(r"""
            set actual_name {tile_gen[1].lane_gen[1].lane_inst~phy_reg1}
            set actual_type reg
            set count 1
            proc get_node_info {option id} {
                if {$option eq "-name"} {
                    if {$id eq "_quartus_sta_kpr__310"} {
                        return {tile_gen[1].lane_gen[1].lane_inst~phy_reg1}
                    }
                    return $::actual_name
                }
                if {$id eq "_quartus_sta_kpr__310"} {return reg}
                return $::actual_type
            }
            proc get_registers {args} {return {_quartus_sta_reg__310}}
            proc get_collection_size {collection} {return $::count}
            proc foreach_in_collection {var collection body} {
                upvar 1 $var node
                foreach node $collection {uplevel 1 $body}
            }
        """)

    def check(self):
        return self.t.call('::c126::diag_collection', '_quartus_sta_kpr__310')

    def test_typed_native_alias_resolves(self):
        self.assertEqual(tuple(self.t.splitlist(self.check())), ('_quartus_sta_reg__310',))

    def test_different_name_rejected(self):
        self.t.setvar('actual_name', 'other_register')
        with self.assertRaisesRegex(Exception, 'NATIVE_OBJECT_IDENTITY_MISMATCH'):
            self.check()

    def test_different_type_rejected(self):
        self.t.setvar('actual_type', 'pin')
        with self.assertRaisesRegex(Exception, 'NATIVE_OBJECT_IDENTITY_MISMATCH'):
            self.check()

    def test_ambiguous_or_missing_rejected(self):
        for count in (0, 2):
            self.t.setvar('count', count)
            with self.assertRaisesRegex(Exception, 'does not resolve exactly once'):
                self.check()


if __name__ == "__main__":
    unittest.main(verbosity=2)
