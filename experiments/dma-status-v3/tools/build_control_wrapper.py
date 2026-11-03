#!/usr/bin/env python3
"""Expose read receipt channels while retaining the original write controller.

Requires the exact external C10 wrapper. Does not provide the containing HIP
connections or fetch/diagnostic consumers, and does not enable DMA admission.
"""
import argparse
import hashlib
import json
from pathlib import Path

SOURCE_SHA256 = 'fdede4e6423db7d8c8b7748cdc0f64b36e4617aefdaa2f96b12663eef5a94268'

PORTS = '''
      output logic RdStatusReady_o,
      output logic RdReceiptValid_o,
      output logic [31:0] RdReceiptData_o,
      input logic RdReceiptConsumed_i,
      input logic RdFetchStatusReady_i,
      output logic RdDiagnosticValid_o,
      input logic RdDiagnosticReady_i,
      output logic [31:0] RdDiagnosticData_o,
      output logic RdProtocolFault_o,
      output logic [31:0] RdProtocolFaultWord_o,
'''

CONNECTIONS = '''
   .DmaRxReady_o          (RdStatusReady_o),
   .DmaAckValid_o         (RdReceiptValid_o),
   .DmaAckData_o          (RdReceiptData_o),
   .DmaAckConsumed_i      (RdReceiptConsumed_i),
   .FetchStatusReady_i    (RdFetchStatusReady_i),
   .StatusDiagnosticValid_o (RdDiagnosticValid_o),
   .StatusDiagnosticReady_i (RdDiagnosticReady_i),
   .StatusDiagnosticData_o  (RdDiagnosticData_o),
   .StatusProtocolFault_o   (RdProtocolFault_o),
   .StatusProtocolFaultWord_o (RdProtocolFaultWord_o),
'''


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Expected one source anchor: ' + old)
    return text.replace(old, new, 1)


def transform(raw):
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError('C10 controller-wrapper source SHA256 mismatch')
    source = raw.decode('utf-8')
    # Preserve the complete write instance and descriptor-fetch wiring verbatim.
    boundary = 'altpcie_dynamic_control  # ('
    prefix, write_tail = source.split(boundary)
    prefix = replace_once(prefix, 'module dma_control #(',
                          'module dma_control_candidate_v3 #(')
    prefix = replace_once(prefix, '      input logic                                  Clk_i,',
                          PORTS + '      input logic                                  Clk_i,')
    prefix = replace_once(prefix, 'altpcie_dynamic_control # (',
                          'altpcie_dynamic_control_candidate_v3 # (\n   .DMA_WIDTH (DMA_WIDTH),')
    prefix = replace_once(prefix, ') read_control            (',
                          ') read_control            (' + CONNECTIONS)
    result = prefix + boundary + write_tail
    if result.split(boundary)[1] != write_tail:
        raise ValueError('Write controller changed')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    raw = args.source.read_bytes()
    result = transform(raw)
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output / 'dma_control_candidate_v3.sv'
    out.write_text(result)
    (args.output / 'manifest.json').write_text(json.dumps({
        'source': str(args.source.resolve()), 'source_sha256': SOURCE_SHA256,
        'output_sha256': hashlib.sha256(out.read_bytes()).hexdigest(),
        'write_controller': 'original, unchanged',
        'integration_complete': False,
        'native_elaboration_verified': False,
        'physical_acceptance': False,
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
