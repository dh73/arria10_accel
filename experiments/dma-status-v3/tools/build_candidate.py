#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Derive v3 from explicitly supplied, source-checked v2 generated files.

Run the unmodified v2 builder first. Its source_manifest, output hashes and
request/packet identity are required. This small derivative does not pretend
that the unavailable full immutable engine was supplied in the reuse packet.
All mutation anchors below are exact token sequences in v2 generated output.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
REQUEST = 'b01a6182-8003-4592-8747-fa414e633637'
REUSE_PACKET_SHA256 = '27c11d6ece5f10960b22e9fecdbe0b137e657eb544ba284f300b47d6371d3a6b'
V2_PACKET_SHA256 = '1b6eb7ecffd7758ca5d0c1e12a29fe9036dc806428137fc5e2f3d87222c988f5'
V2_PREFIX = 'qualification/dma-status-contract-candidate-v2/'
SUPPLIED = ('rtl/dma_owner_v2.sv', 'rtl/dma_status_sink_v2.sv',
            'rtl/dma_status_v2_pkg.sv', 'rtl/engine_v2_declarations.svh',
            'rtl/engine_v2_logic.svh', 'tools/controller_transform.py')

NEW_INGRESS = '''
// Candidate-v3 keeps wire version2. Only an accepted fetch success reaches
// the retained legacy register. The sink's FETCH_FENCE edge allows the legacy
// consumer to sample it before the held receipt can reach the owner.
// synthesis translate_off
initial if (READ_CONTROL != 1 || DMA_WIDTH != 256)
  $fatal(1, "candidate-v3 controller requires READ_CONTROL=1 and DMA_WIDTH=256");
// synthesis translate_on
logic v3_fetch_valid;
logic [31:0] v3_fetch_word;
logic v2_status_accept;
assign v2_status_accept = DmaRxValid_i && DmaRxReady_o;
always_ff @(posedge Clk_i or negedge Rstn_i) begin
  if (!Rstn_i) begin
    dma_status_reg <= 32'h0;
    dma_status_valid_reg <= 1'b0;
  end else begin
    dma_status_reg <= (v3_fetch_valid && FetchStatusReady_i) ?
                     {23'b0, 1'b1, v3_fetch_word[7:0]} : 32'h0;
    dma_status_valid_reg <= v3_fetch_valid && FetchStatusReady_i;
  end
end
// No pulse adapter or independent delayed ACK copy remains. The sink owns
// the entire held-valid/four-phase channel, including fetch's extra edge.
// synthesis translate_off
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  $rose(DmaAckValid_o) && DmaAckData_o[7] |->
    $past(dma_status_valid_reg) &&
    $past(dma_status_reg[7:0]) == DmaAckData_o[7:0]);
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  DmaAckValid_o && !DmaAckConsumed_i |=>
    DmaAckValid_o && $stable(DmaAckData_o));
// synthesis translate_on
'''

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def load_transform(v2_root: Path):
    path = v2_root / 'tools/controller_transform.py'
    spec = importlib.util.spec_from_file_location('candidate_v2_controller_transform', path)
    if spec is None or spec.loader is None:
        raise ValueError(f'cannot load supplied transform: {path}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def verify_packet(packet: Path, v2_root: Path) -> None:
    raw = packet.read_bytes()
    if digest(raw) != REUSE_PACKET_SHA256:
        raise ValueError('reuse source packet SHA-256 differs from request')
    parts = re.split(r'^FILE ([^\n]+)\n', raw.decode('utf-8'), flags=re.M)
    sections = {}
    for i in range(1, len(parts), 2):
        if parts[i] in sections:
            raise ValueError(f'duplicate packet section: {parts[i]}')
        sections[parts[i]] = parts[i+1]
    for rel in SUPPLIED:
        key = V2_PREFIX + rel
        if key not in sections:
            raise ValueError(f'missing supplied section: {key}')
        # Only outer packet separators are ignored. In particular, Python
        # indentation, strings, comments and code remain exactly source-bound.
        if (v2_root / rel).read_text().strip() != sections[key].strip():
            raise ValueError(f'v2 baseline differs from supplied reuse packet: {key}')

def transform_engine(source: str, t) -> str:
    result = t._replace(source, 'module altpcieav_dma_rd_candidate_v2 # (',
                        'module altpcieav_dma_rd_candidate_v3 # (', 'v2 engine module')
    result = t._replace(result, 'input logic [31:0] RdDmaAckData_i,',
                        'input logic [31:0] RdDmaAckData_i,\noutput logic RdDmaAckConsumed_o,',
                        'receipt reverse port')
    result = t._replace(result, '`include "engine_v2_logic.svh"',
                        '`include "engine_v3_logic.svh"', 'owner integration include')
    # Declarations and all payload/tag/controller-FIFO logic are inherited.
    t._locate(result, '`include "engine_v2_declarations.svh"', 'unchanged engine declarations')
    return result

def transform_controller(source: str, t) -> str:
    result = t._replace(source, 'module altpcie_dynamic_control_candidate_v2 #(',
                        'module altpcie_dynamic_control_candidate_v3 #(', 'v2 controller module')
    result = t._replace(result, 'output logic [31:0] DmaAckData_o,',
                        'output logic [31:0] DmaAckData_o,\ninput logic DmaAckConsumed_i,',
                        'receipt reverse port')
    # These comments are synthesis directives, not ignorable whitespace.
    # Token replacement leaves the outer translate_off/on in the source.
    # Require the entire source-bound region, including both directive edges.
    if result.count(t._NEW_INGRESS) != 1:
        raise ValueError('complete v2 ingress including synthesis directives differs')
    result = result.replace(t._NEW_INGRESS, NEW_INGRESS, 1)
    end = t._NEW_END.replace('Candidate-v2', 'Candidate-v3')
    end = end.replace('dma_status_sink_v2 #', 'dma_status_sink_v3 #')
    end = end.replace('v2_fetch_valid', 'v3_fetch_valid').replace('v2_fetch_word', 'v3_fetch_word')
    end = end.replace('.retired_ack_valid(v2_sink_ack_valid), .retired_ack_word(v2_sink_ack_word),',
                      '.retired_ack_valid(DmaAckValid_o), .retired_ack_word(DmaAckData_o),\n'
                      '  .retired_ack_consumed(DmaAckConsumed_i),')
    result = t._replace(result, t._NEW_END, end, 'sink with connected receipt closure')
    # Refuse an unexpected residual reader/writer outside supplied anchors.
    forbidden = {'v2_fetch_ack_valid', 'v2_fetch_ack_word', 'v2_sink_ack_valid',
                 'v2_sink_ack_word', 'dma_status_sink_v2'}
    leftovers = forbidden & {tok for tok, _, _ in t._tokens(result)}
    if leftovers:
        raise ValueError(f'unreviewed legacy ACK consumer(s): {sorted(leftovers)}')
    return result

def derive(v2_generated: Path, v2_root: Path) -> tuple[dict[str, str], dict]:
    manifest = json.loads((v2_generated / 'source_manifest.json').read_text())
    if (manifest.get('request_id') != 'acc7af21-c803-482b-9091-de72f0546592' or
        manifest.get('source_packet_sha256') != V2_PACKET_SHA256 or
        manifest.get('production_contract_valid') is not False):
        raise ValueError('v2 source manifest request/packet/contract identity differs')
    names = ('altpcieav_dma_rd_candidate_v2.sv',
             'altpcie_dynamic_control_candidate_v2.sv', 'altpcie_fifo.sv')
    raw = {name: (v2_generated / name).read_bytes() for name in names}
    for name, data in raw.items():
        if manifest.get('outputs', {}).get(name) != digest(data):
            raise ValueError(f'v2 generated output hash mismatch: {name}')
    audit = manifest.get('controller', {})
    if audit.get('unprovided_removed_signal_consumers') != []:
        raise ValueError('v2 omitted-controller consumer audit missing or not clear')
    t = load_transform(v2_root)
    generated = {
        'altpcieav_dma_rd_candidate_v3.sv': transform_engine(raw[names[0]].decode(), t),
        'altpcie_dynamic_control_candidate_v3.sv': transform_controller(raw[names[1]].decode(), t),
        'altpcie_fifo.sv': raw[names[2]].decode(),
    }
    return generated, manifest

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source-packet', required=True, type=Path, help='dma-owner-reuse-v1/source-packet.txt')
    ap.add_argument('--v2-root', type=Path, default=ROOT.with_name('dma-status-v2'))
    ap.add_argument('--v2-generated', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    try:
        verify_packet(args.source_packet, args.v2_root)
        generated, prior = derive(args.v2_generated, args.v2_root)
        out = args.out.resolve()
        inputs = [args.source_packet.resolve(), args.v2_root.resolve(), args.v2_generated.resolve()]
        if out.exists() or any(out == p or out.is_relative_to(p) or p.is_relative_to(out) for p in inputs):
            raise ValueError('--out must be a new isolated directory outside all input trees')
        out.mkdir(parents=True)
        for name, data in generated.items():
            (out / name).write_text(data)
        report = {
            'request_id': REQUEST, 'source_packet_sha256': REUSE_PACKET_SHA256,
            'production_contract_valid': False, 'wire_status_version': 2,
            'receipt_protocol': 'held-valid / consumed / valid-low / consumed-low',
            'prior_source_manifest': prior,
            'outputs': {name: digest(data.encode()) for name, data in generated.items()},
            'full_containing_shell_supplied': False,
            'rtl_equivalence_proved': False, 'vcs_executed_by_builder': False,
        }
        (out / 'source_manifest.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f'Generated isolated candidate-v3: {out}')
        return 0
    except (OSError, ValueError, KeyError) as error:
        ap.exit(2, f'REFUSED: {error}\n')

if __name__ == '__main__':
    raise SystemExit(main())
