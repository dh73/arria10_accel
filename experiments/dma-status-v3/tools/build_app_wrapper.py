#!/usr/bin/env python3
"""Expose v3 read-mover channels in the exact external C10 application shell."""
import argparse
import hashlib
import json
from pathlib import Path

from build_control_wrapper import replace_once

SOURCE_SHA256 = '158337c2fe27c4c6bbee98a7234c5923c74ce320dc6ecfca61c15185c5cdbce1'
PORTS = '''
   input logic RdStatusReady_i,
   input logic RdReceiptValid_i,
   input logic [31:0] RdReceiptData_i,
   output logic RdReceiptConsumed_o,
   output logic RdControlReady_o,
   output logic RdContractFault_o,
'''
CONNECTIONS = '''
      .RdDmaTxReady_i (RdStatusReady_i),
      .RdDmaAckValid_i (RdReceiptValid_i),
      .RdDmaAckData_i (RdReceiptData_i),
      .RdDmaAckConsumed_o (RdReceiptConsumed_o),
      .RdDMACntrlReady_o (RdControlReady_o),
      .ContractFault_o (RdContractFault_o),
'''
INACTIVE = '''
     assign RdReceiptConsumed_o = 1'b0;
     assign RdControlReady_o = 1'b0;
     assign RdContractFault_o = 1'b0;
'''


def transform(raw):
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError('C10 application source SHA256 mismatch')
    source = raw.decode('utf-8')
    result = replace_once(source, 'module altpcieav_256_app\n',
                          'module altpcieav_256_app_candidate_v3\n')
    result = replace_once(result, '/// System Clock and Reset\n',
                          PORTS + '\n/// System Clock and Reset\n')
    result = replace_once(result, '   altpcieav_dma_rd               # (',
                          '   altpcieav_dma_rd_candidate_v3  # (')
    result = replace_once(result, '   ) read_data_mover                (',
                          '   ) read_data_mover                (' + CONNECTIONS)
    result = replace_once(result,
        "     assign AvRdDmaWrite_o             = 1'b0;",
        INACTIVE + "     assign AvRdDmaWrite_o             = 1'b0;")
    # All edits precede this boundary; preserve the complete write-side tail.
    boundary = '//DMA write data mover\n'
    if result.split(boundary)[1] != source.split(boundary)[1]:
        raise ValueError('Write mover or downstream application logic changed')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = transform(args.source.read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output / 'altpcieav_256_app_candidate_v3.sv'
    out.write_text(result)
    (args.output / 'manifest.json').write_text(json.dumps({
        'source': str(args.source.resolve()), 'source_sha256': SOURCE_SHA256,
        'output_sha256': hashlib.sha256(out.read_bytes()).hexdigest(),
        'write_mover_and_downstream_logic': 'original, unchanged',
        'read_engine_reset': 'existing Rstn_i[6]',
        'control_load': 'existing constant zero; no new control admission',
        'integration_complete': False,
        'native_elaboration_verified': False,
        'physical_acceptance': False,
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
