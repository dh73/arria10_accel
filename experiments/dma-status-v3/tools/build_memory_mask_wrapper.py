#!/usr/bin/env python3
"""Expose read byte enables in a separate, exact-source 256-bit DMA candidate."""
import argparse
import hashlib
import json
from pathlib import Path
from build_control_wrapper import replace_once

PARENT_SHA = 'c78881a92c6f6e1aee6ee2b39c9d392e4ccd7a85ae054ed7ffbc9a0bfa38dd3a'
TOP_SHA = '6017cfa81442c15a027ea9d544e3a15006b377e99f21fc286ad303c496bf8af6'


def transform(parent, top):
    if hashlib.sha256(parent).hexdigest() != PARENT_SHA or hashlib.sha256(top).hexdigest() != TOP_SHA:
        raise ValueError('Expected exact fetch-port parent and configured wrapper')
    p = parent.decode()
    t = top.decode()
    p = replace_once(p, 'module c10_receipt_parent_candidate_v3 # (',
                     'module c10_memory_mask_parent_v3 # (')
    p = replace_once(p, '      input wire CandidateRdFetchStatusReady_i,',
                     '      output wire [31:0] wr_dma_read_byte_enable_o,\n'
                     '      input wire CandidateRdFetchStatusReady_i,')
    p = replace_once(p, '            .AvWrDmaRead_o',
                     '            .AvWrDmaReadByteEnable_o (wr_dma_read_byte_enable_o),\n'
                     '            .AvWrDmaRead_o')
    t = replace_once(t, 'module c10_configured_candidate_v3 (',
                     'module c10_memory_mask_configured_v3 (\n'
                     '      output wire [31:0] wr_dma_read_byte_enable_o,')
    t = replace_once(t, 'c10_receipt_parent_candidate_v3 #(',
                     'c10_memory_mask_parent_v3 #(')
    t = replace_once(t, ') dut (', ') dut (\n'
                     '        .wr_dma_read_byte_enable_o(wr_dma_read_byte_enable_o),')
    return p, t


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--configured', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    a = parser.parse_args()
    parent, top = transform(a.parent.read_bytes(), a.configured.read_bytes())
    a.output.mkdir(parents=True, exist_ok=False)
    outputs = {'c10_memory_mask_parent_v3.sv': parent,
               'c10_memory_mask_configured_v3.sv': top}
    for name, text in outputs.items(): (a.output/name).write_text(text)
    (a.output/'manifest.json').write_text(json.dumps({
        'input_parent_sha256': PARENT_SHA, 'input_configured_sha256': TOP_SHA,
        'outputs': {n: hashlib.sha256(s.encode()).hexdigest() for n,s in outputs.items()},
        'scope': 'fixed 256-bit internal-controller AVMM configuration',
        'memory_fabric_consumes_mask': False, 'physical_acceptance': False,
    }, indent=2) + '\n')


if __name__ == '__main__': main()
