#!/usr/bin/env python3
"""Connect the two v3 wrappers inside the exact external C10 HIP parent.

This candidate exposes fetch/error consumers; it does not supply them.
Only the internal-controller, 256-bit AVMM DMA configuration is supported.
"""
import argparse
import hashlib
import json
from pathlib import Path

from build_control_wrapper import replace_once

SOURCE_SHA256 = '9fa06ad3caeeb1887ddde9326e7d5a72e867a953e3a59cea6d2b201e548f98fa'
ORIGINAL = 'pcie_ed_DUT_altera_pcie_a10_hip_2023_ygrj5ua'
PORTS = '''
      input wire CandidateRdFetchStatusReady_i,
      output wire CandidateRdFetchStatusValid_o,
      output wire [31:0] CandidateRdFetchStatusData_o,
      output wire CandidateRdDiagnosticValid_o,
      input wire CandidateRdDiagnosticReady_i,
      output wire [31:0] CandidateRdDiagnosticData_o,
      output wire CandidateRdProtocolFault_o,
      output wire [31:0] CandidateRdProtocolFaultWord_o,
      output wire CandidateRdContractFault_o,
      output wire CandidateRdControlReady_o,
'''
WIRES = '''
wire candidate_rd_status_ready;
wire candidate_rd_receipt_valid;
wire [31:0] candidate_rd_receipt_data;
wire candidate_rd_receipt_consumed;
// synthesis translate_off
initial begin
   if (internal_controller_hwtcl != 1 || interface_type_integer_hwtcl != 1 ||
       include_dma_hwtcl != 1 || enable_ast_trs_hwtcl != 0 ||
       dma_width_hwtcl != 256 ||
       (cb_pcie_mode_hwtcl == 1 && cb_pcie_rx_lite_hwtcl_local == 1))
      $fatal(1, "v3 parent requires internal-controller 256-bit AVMM DMA");
end
// synthesis translate_on
'''
CONTROL = '''
         .RdStatusReady_o (candidate_rd_status_ready),
         .RdReceiptValid_o (candidate_rd_receipt_valid),
         .RdReceiptData_o (candidate_rd_receipt_data),
         .RdReceiptConsumed_i (candidate_rd_receipt_consumed),
         .RdFetchStatusReady_i (CandidateRdFetchStatusReady_i),
         .RdFetchStatusValid_o (CandidateRdFetchStatusValid_o),
         .RdFetchStatusData_o (CandidateRdFetchStatusData_o),
         .RdDiagnosticValid_o (CandidateRdDiagnosticValid_o),
         .RdDiagnosticReady_i (CandidateRdDiagnosticReady_i),
         .RdDiagnosticData_o (CandidateRdDiagnosticData_o),
         .RdProtocolFault_o (CandidateRdProtocolFault_o),
         .RdProtocolFaultWord_o (CandidateRdProtocolFaultWord_o),
'''
APP = '''
            .RdStatusReady_i (candidate_rd_status_ready),
            .RdReceiptValid_i (candidate_rd_receipt_valid),
            .RdReceiptData_i (candidate_rd_receipt_data),
            .RdReceiptConsumed_o (candidate_rd_receipt_consumed),
            .RdControlReady_o (CandidateRdControlReady_o),
            .RdContractFault_o (CandidateRdContractFault_o),
'''


def transform(raw):
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError('C10 parent source SHA256 mismatch')
    source = raw.decode('utf-8')
    result = replace_once(source, 'module ' + ORIGINAL + ' # (',
                          'module c10_receipt_parent_candidate_v3 # (')
    result = replace_once(result, ') (\n      // Control signals',
                          ') (' + PORTS + '\n      // Control signals')
    result = replace_once(result, 'wire dut_rd_ast_tx_valid;\n',
                          'wire dut_rd_ast_tx_valid;\n' + WIRES)
    result = replace_once(result, '      dma_control            # (',
                          '      dma_control_candidate_v3 # (')
    result = replace_once(result, '      ) dma_control_0          (',
                          '      ) dma_control_0          (' + CONTROL)
    result = replace_once(result, '         altpcieav_256_app                # (',
                          '         altpcieav_256_app_candidate_v3 # (')
    result = replace_once(result, '         ) altpcieav_256_app (',
                          '         ) altpcieav_256_app (' + APP)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = transform(args.source.read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output / 'c10_receipt_parent_candidate_v3.sv'
    out.write_text(result)
    (args.output / 'manifest.json').write_text(json.dumps({
        'source': str(args.source.resolve()), 'source_sha256': SOURCE_SHA256,
        'output_sha256': hashlib.sha256(out.read_bytes()).hexdigest(),
        'supported_configuration': 'internal-controller 256-bit AVMM DMA only',
        'configuration_check': 'simulation guard; synthesis configuration must be separately qualified',
        'fetch_and_diagnostic_consumers_implemented': False,
        'native_elaboration_verified': False, 'physical_acceptance': False,
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
