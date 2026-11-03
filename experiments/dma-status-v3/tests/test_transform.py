#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Unit-check supplied transformation anchors. Fixtures are NOT full RTL."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_v3', ROOT / 'tools/build_candidate.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
V2 = ROOT.with_name('dma-status-v2')
T = build.load_transform(V2)

ENGINE = '''// synthetic token anchor fixture, NOT the vendor engine
module altpcieav_dma_rd_candidate_v2 # (parameter P = 1) (
input logic [31:0] RdDmaAckData_i,
output logic ContractFault_o
);
`include "engine_v2_declarations.svh"
`include "engine_v2_logic.svh"
endmodule
'''
CONTROLLER = '''// synthetic supplied-region fixture, NOT the full controller
module altpcie_dynamic_control_candidate_v2 #(parameter P = 1) (
output logic [31:0] DmaAckData_o,
input logic Clk_i
);
''' + T._NEW_INGRESS + '\n' + T._NEW_END + '\nendmodule\n'

class TransformTests(unittest.TestCase):
    def test_engine_reverse_port_and_only_three_edits(self):
        out = build.transform_engine(ENGINE, T)
        self.assertIn('output logic RdDmaAckConsumed_o,', out)
        self.assertIn('"engine_v3_logic.svh"', out)
        self.assertIn('"engine_v2_declarations.svh"', out)
        undo = out.replace('candidate_v3', 'candidate_v2').replace(
            'input logic [31:0] RdDmaAckData_i,\noutput logic RdDmaAckConsumed_o,',
            'input logic [31:0] RdDmaAckData_i,').replace('engine_v3_logic', 'engine_v2_logic')
        self.assertEqual(undo, ENGINE)

    def test_controller_direct_closed_receipt_and_fetch_fence(self):
        out = build.transform_controller(CONTROLLER, T)
        self.assertIn('input logic DmaAckConsumed_i,', out)
        self.assertIn('output logic FetchStatusValid_o,', out)
        self.assertIn('output logic [31:0] FetchStatusData_o,', out)
        self.assertIn('assign FetchStatusValid_o = v3_fetch_valid;', out)
        self.assertIn('assign FetchStatusData_o = v3_fetch_word;', out)
        self.assertIn('.retired_ack_consumed(DmaAckConsumed_i)', out)
        self.assertIn('.retired_ack_valid(DmaAckValid_o)', out)
        self.assertIn('.retired_ack_word(DmaAckData_o)', out)
        self.assertNotIn('v2_fetch_ack_valid', out)
        self.assertNotIn('v2_sink_ack_valid', out)
        self.assertIn('dma_status_sink_v3 #', out)
        self.assertIn('dma_status_valid_reg <= v3_fetch_valid && FetchStatusReady_i;', out)
        self.assertIn("dma_status_v2_pkg::status_v2_success(DmaRxData_i)", out)
        self.assertIn("pending_desc_update_array[v2_i] <= 1'b0;", out)

    def test_ingress_synthesis_boundaries_preserve_functional_logic(self):
        out = build.transform_controller(CONTROLLER, T)
        disabled = False
        visible = []
        for line in out.splitlines():
            if '// synthesis translate_off' in line:
                self.assertFalse(disabled, 'nested synthesis exclusion')
                disabled = True
            elif '// synthesis translate_on' in line:
                self.assertTrue(disabled, 'unmatched synthesis inclusion')
                disabled = False
            elif not disabled:
                visible.append(line)
        self.assertFalse(disabled)
        functional = '\n'.join(visible)
        self.assertIn('dma_status_valid_reg <= v3_fetch_valid && FetchStatusReady_i;', functional)
        self.assertIn('logic v3_fetch_valid;', functional)
        self.assertNotIn('$fatal', functional)
        self.assertNotIn('assert property', functional)

    def test_changed_directive_refused(self):
        altered = CONTROLLER.replace('// synthesis translate_off', '// removed directive', 1)
        with self.assertRaisesRegex(ValueError, 'synthesis directives'):
            build.transform_controller(altered, T)

    def test_missing_or_duplicate_engine_anchor_refused(self):
        for bad in (ENGINE.replace('RdDmaAckData_i', 'foreign_ack'), ENGINE + ENGINE):
            with self.assertRaises(ValueError): build.transform_engine(bad, T)

    def test_changed_fetch_adapter_refused(self):
        bad = CONTROLLER.replace('v2_fetch_ack_valid <= 1\'b0;', 'v2_fetch_ack_valid <= 1\'b1;')
        with self.assertRaises(ValueError): build.transform_controller(bad, T)

    def test_omitted_ack_consumer_refused(self):
        with self.assertRaises(ValueError):
            build.transform_controller(CONTROLLER.replace('endmodule',
                'assign unprovided = v2_sink_ack_valid;\nendmodule'), T)

    def test_manifest_binding_and_hash_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            fixture = {'altpcieav_dma_rd_candidate_v2.sv': ENGINE,
                       'altpcie_dynamic_control_candidate_v2.sv': CONTROLLER,
                       'altpcie_fifo.sv': '// synthetic FIFO fixture\n'}
            manifest = {'request_id': 'acc7af21-c803-482b-9091-de72f0546592',
                        'source_packet_sha256': build.V2_PACKET_SHA256,
                        'production_contract_valid': False,
                        'controller': {'unprovided_removed_signal_consumers': []},
                        'outputs': {k: build.digest(v.encode()) for k, v in fixture.items()}}
            for name, data in fixture.items(): (path/name).write_text(data)
            (path/'source_manifest.json').write_text(json.dumps(manifest))
            generated, _ = build.derive(path, V2)
            self.assertEqual(generated['altpcie_fifo.sv'], fixture['altpcie_fifo.sv'])
            (path/'altpcie_fifo.sv').write_text('mutated')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                build.derive(path, V2)

    def test_wrong_reuse_packet_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'packet.txt'
            path.write_text('not the supplied packet')
            with self.assertRaisesRegex(ValueError, 'SHA-256'):
                build.verify_packet(path, V2)

if __name__ == '__main__':
    unittest.main()
