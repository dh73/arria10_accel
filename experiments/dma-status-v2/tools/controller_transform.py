# SPDX-License-Identifier: BSD-3-Clause
"""Transform only the controller regions supplied in the request.

The full controller is an explicit caller input, not a discovered local path.
Unseen middle regions are preserved byte-for-byte. Their consumer-site inventory
is a review gate, not a claim that descriptor fetch/full HIP was qualified.
"""
from __future__ import annotations
import hashlib
import re

_TOKEN = re.compile(
    r'(?P<skip>\s+|//[^\n]*|/\*.*?\*/)|'
    r'"(?:\\.|[^"\\])*"|\\\S+|[A-Za-z_$][A-Za-z0-9_$]*|'
    r"[0-9]+'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+|'[01xXzZ]|[0-9]+|"
    r'===|!==|==|!=|<=|>=|&&|\|\||<<|>>|\+\+|--|::|.', re.S)

def _tokens(text: str):
    return [(m.group(), m.start(), m.end()) for m in _TOKEN.finditer(text)
            if m.lastgroup != 'skip']

def _locate(source: str, old: str, name: str):
    seq = _tokens(source)
    wanted = [x[0] for x in _tokens(old)]
    values = [x[0] for x in seq]
    matches = [i for i in range(len(values)-len(wanted)+1)
               if values[i:i+len(wanted)] == wanted]
    if len(matches) != 1:
        raise ValueError(f'{name}: expected one exact supplied-token anchor; got {len(matches)}')
    i = matches[0]
    return seq[i][1], seq[i+len(wanted)-1][2]

def _replace(source: str, old: str, new: str, name: str):
    start, end = _locate(source, old, name)
    return source[:start] + new + source[end:]

_OLD_INGRESS = '''
always_ff @(posedge Clk_i or negedge Rstn_i) begin
if(~Rstn_i) begin
dma_status_reg <= 32'h0;
dma_status_valid_reg <= 1'b1;
end
else begin
dma_status_reg <= DmaRxData_i;
dma_status_valid_reg <= DmaRxValid_i;
end
end
'''
_NEW_INGRESS = '''
// Candidate-v2: only qualified fetch SUCCESS reaches the legacy fetch logic.
// FetchStatusReady_i is an explicit omitted-consumer acceptance obligation.
// synthesis translate_off
initial if (READ_CONTROL != 1 || DMA_WIDTH != 256)
  $fatal(1, "candidate-v2 controller requires READ_CONTROL=1 and DMA_WIDTH=256");
// synthesis translate_on
logic v2_fetch_valid;
logic [31:0] v2_fetch_word;
logic v2_status_accept;
logic v2_sink_ack_valid;
logic [31:0] v2_sink_ack_word;
logic v2_fetch_ack_valid;
logic [31:0] v2_fetch_ack_word;
assign v2_status_accept = DmaRxValid_i && DmaRxReady_o;
always_ff @(posedge Clk_i or negedge Rstn_i) begin
  if (!Rstn_i) begin
    dma_status_reg <= 32'h0;
    dma_status_valid_reg <= 1'b0;
  end else begin
    dma_status_reg <= (v2_fetch_valid && FetchStatusReady_i) ?
                      {23'b0, 1'b1, v2_fetch_word[7:0]} : 32'h0;
    dma_status_valid_reg <= v2_fetch_valid && FetchStatusReady_i;
  end
end
// The legacy fetch consumer observes the retained ingress register one edge
// later. Keep the full owner token until that edge before returning its ack.
always_ff @(posedge Clk_i or negedge Rstn_i) begin
  if (!Rstn_i) begin
    v2_fetch_ack_valid <= 1'b0;
    v2_fetch_ack_word <= 32'h0;
  end else begin
    v2_fetch_ack_valid <= v2_sink_ack_valid && v2_sink_ack_word[7];
    if (v2_sink_ack_valid && v2_sink_ack_word[7])
      v2_fetch_ack_word <= v2_sink_ack_word;
  end
end
assign DmaAckValid_o = v2_fetch_ack_valid ||
                      (v2_sink_ack_valid && !v2_sink_ack_word[7]);
assign DmaAckData_o = v2_fetch_ack_valid ? v2_fetch_ack_word : v2_sink_ack_word;
// The sink's IDLE dispatch cycle separates acknowledgements by >=2 clocks.
// synthesis translate_off
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  !(v2_fetch_ack_valid && v2_sink_ack_valid));
// synthesis translate_on
'''
# Token hash of the supplied ep_last_fifo through final DCMAddress assignment region.
_END_SHA256 = 'b89a077cbe811c0b5f117ccd378842a6edf4de832a0eb6b84e4f6ecca6966d87'
_END_START = 'altpcie_fifo #(.FIFO_DEPTH(128), .DATA_WIDTH(9)) ep_last_fifo'
_END_FINISH = 'assign DCMAddress_o[63:0] = (dcm_state[1])? ep_last_update_address_reg : MsiInterface_i[63:0];'

def _controller_end(source: str):
    a, _ = _locate(source, _END_START, 'status-region start')
    _, b = _locate(source, _END_FINISH, 'status-region end')
    if b <= a:
        raise ValueError('reversed controller status boundaries')
    digest = hashlib.sha256(' '.join(t[0] for t in _tokens(source[a:b])).encode()).hexdigest()
    if digest != _END_SHA256:
        raise ValueError('supplied controller status-region token hash differs')
    return a, b

_NEW_END = '''
// Candidate-v2: preserve pending MSI ownership through nonterminal/error
// notifications. Only accepted exact data success consumes the pending bit.
generate
  for (genvar v2_i = 0; v2_i < 128; v2_i = v2_i + 1) begin: v2_pending_msi
    always_ff @(posedge Clk_i or negedge Rstn_i) begin
      if (!Rstn_i)
        pending_desc_update_array[v2_i] <= 1'b0;
      else if (DCSWriteData_i[7:0] == v2_i && ep_last_pntr_not_from_pending_wen)
        pending_desc_update_array[v2_i] <= 1'b1;
      else if (DCSWriteData_i[7:0] == v2_i && pending_desc_id_wen)
        pending_desc_update_array[v2_i] <= 1'b1;
      else if (v2_status_accept && !DmaRxData_i[7] &&
               DmaRxData_i[6:0] == v2_i &&
               dma_status_v2_pkg::status_v2_success(DmaRxData_i))
        pending_desc_update_array[v2_i] <= 1'b0;
    end
  end
endgenerate
// ctrl_reg[0] no longer suppresses candidate status publication. Every data
// status is transported; only exact success becomes host flag1. Fetch IDs are
// never truncated into a data-status row. The rest of the controller, including
// omitted fetch consumers and register programming, remains unqualified.
dma_status_sink_v2 #(.DEPTH(16)) v2_status_sink (
  .clk(Clk_i), .rstn(Rstn_i),
  .s_valid(DmaRxValid_i), .s_ready(DmaRxReady_o), .s_word(DmaRxData_i),
  .s_msi(!DmaRxData_i[7] && pending_desc_update_array[DmaRxData_i[6:0]]),
  .header_base({dt_hi_src_addr_reg, dt_low_src_addr_reg}),
  .msi_interface(MsiInterface_i),
  .dcm_write(DCMWrite_o), .dcm_address(DCMAddress_o),
  .dcm_data(DCMWriteData_o), .dcm_byteenable(DCMByteEnable_o),
  .dcm_waitrequest(DCMWaitRequest_i),
  .fetch_valid(v2_fetch_valid), .fetch_ready(FetchStatusReady_i),
  .fetch_word(v2_fetch_word),
  .diagnostic_valid(StatusDiagnosticValid_o),
  .diagnostic_ready(StatusDiagnosticReady_i),
  .diagnostic_word(StatusDiagnosticData_o),
  .retired_ack_valid(v2_sink_ack_valid), .retired_ack_word(v2_sink_ack_word),
  .protocol_fault(StatusProtocolFault_o),
  .fault_word(StatusProtocolFaultWord_o)
);
assign DCMRead_o = 1'b0;
'''

_REMOVED_STATUS_SIGNALS = {
    'ep_last_fifo_wrreq', 'ep_last_fifo_rdreq', 'ep_last_data',
    'ep_last_to_rc', 'ep_last_fifo_count', 'ep_last_from_dma',
    'ep_last_fifo_wrreq_array', 'msi_array', 'ep_last_fifo_wrreq_array_or1',
    'ep_last_fifo_wrreq_array_or2', 'msi_array_or1', 'msi_array_or2',
    'ep_last_from_dma_r', 'dcm_state', 'dcm_nxt_state',
    'ep_last_update_address_reg',
}

def controller_audit(source: str) -> dict:
    """List all legacy status consumer lines without certifying their semantics."""
    ingress_start, ingress_end = _locate(source, _OLD_INGRESS, 'status ingress')
    end_start, end_end = _controller_end(source)
    consumers = []
    removed_consumers = []
    removed_sites = []
    # Keep offsets while removing comments/strings before declaration matching.
    clean = list(source)
    for match in _TOKEN.finditer(source):
        if match.lastgroup == 'skip' and not match.group().isspace():
            clean[match.start():match.end()] = ' ' * (match.end()-match.start())
        elif match.group().startswith('"'):
            clean[match.start():match.end()] = ' ' * (match.end()-match.start())
    clean = ''.join(clean)
    declarations = [(m.start(), m.end()) for m in
                    re.finditer(r'\b(?:logic|reg|wire)\b[^;]*;', clean)]
    def is_declaration_site(start):
        for a, b in declarations:
            if a <= start < b:
                prefix = clean[a:start]
                return ('=' not in prefix and
                        prefix.count('[') == prefix.count(']'))
        return False
    lines = source.splitlines()
    for token, start, _ in _tokens(source):
        if token in _REMOVED_STATUS_SIGNALS and not end_start <= start < end_end:
            line = source.count('\n', 0, start) + 1
            declaration = is_declaration_site(start)
            site = {'line': line, 'signal': token,
                    'declaration_only': declaration,
                    'text': lines[line-1].strip()}
            removed_sites.append(site)
            if not declaration:
                removed_consumers.append(site)
        if token in {'dma_status_reg', 'dma_status_valid_reg'}:
            line = source.count('\n', 0, start) + 1
            consumers.append({
                'line': line, 'signal': token,
                'in_transformed_supplied_region':
                    ingress_start <= start < ingress_end or end_start <= start < end_end,
                'text': source.splitlines()[line-1].strip(),
            })
    return {
        'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
        'legacy_status_sites': consumers,
        'removed_signal_sites_outside_supplied_region': removed_sites,
        'unprovided_removed_signal_consumers': removed_consumers,
        'omitted_consumer_semantics_qualified': False,
        'fetch_ready_is_explicit_acceptance_gate': True,
        'full_controller_fetch_hip_linux_exercised': False,
    }

def transform_controller(source: str) -> str:
    """Return a separate candidate module; never modifies the source file."""
    # Refuse to apply to already transformed source or to different visible logic.
    audit = controller_audit(source)
    if audit['unprovided_removed_signal_consumers']:
        sites = ', '.join(f"{x['signal']}@{x['line']}" for x in
                          audit['unprovided_removed_signal_consumers'])
        raise ValueError('omitted controller logic reads removed status signals; '
                         'supply/review those exact regions before integration: ' + sites)
    result = _replace(source, 'module altpcie_dynamic_control #(',
                      'module altpcie_dynamic_control_candidate_v2 #(', 'module declaration')
    result = _replace(result, 'input logic [159:0] WrDescTxData_i );', '''
input logic [159:0] WrDescTxData_i,
output logic DmaRxReady_o,
output logic DmaAckValid_o,
output logic [31:0] DmaAckData_o,
input logic FetchStatusReady_i,
output logic StatusDiagnosticValid_o,
input logic StatusDiagnosticReady_i,
output logic [31:0] StatusDiagnosticData_o,
output logic StatusProtocolFault_o,
output logic [31:0] StatusProtocolFaultWord_o
);''', 'new candidate interface')
    result = _replace(result, _OLD_INGRESS, _NEW_INGRESS, 'status ingress')
    a, b = _controller_end(result)
    result = result[:a] + _NEW_END + result[b:]
    return result
