#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Derive isolated fetch consumers; never copy generated vendor RTL into git.

--controller is the exact private v3 controller from the supplied packet.
--write-controller is its ORIGINAL licensed source, checked by regenerating v3.
Optional shell inputs are the originals accepted by the pinned v3 builders.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
V3 = ROOT.parent / 'dma-status-v3'
V2 = ROOT.parent / 'dma-status-v2'
CONTROLLER_SHA = '08880eb036b19f396e4f9f40675b890574c719454e9a57b88c45c06fe3059a36'
PIN = 'd2067f6136c7afe218ab42a2136e27167ddd0826'
REQUEST = '463087a8-4300-4c4a-9246-ddac733e539b'

def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

T = load(V2 / 'tools/controller_transform.py', 'source_tokens')
sys.path.insert(0, str(V3 / 'tools'))
C3 = load(V3 / 'tools/build_candidate.py', 'candidate3')

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def once(s, old, new):
    if s.count(old) != 1:
        raise ValueError(f'expected one anchor: {old[:100]}')
    return s.replace(old, new, 1)

def span(s, start, end, replacement):
    if s.count(start)!=1 or s.count(end)!=1:
        raise ValueError('nonunique region boundaries')
    a=s.index(start); b=s.index(end, a)
    return s[:a]+replacement+'\n'+s[b:]

def tokens(s, old, new, count=1):
    seq=T._tokens(s); want=[x[0] for x in T._tokens(old)]
    values=[x[0] for x in seq]
    hits=[i for i in range(len(values)-len(want)+1) if values[i:i+len(want)]==want]
    if len(hits)!=count: raise ValueError(f'expected {count} token anchors: {old[:90]}; got {len(hits)}')
    for i in reversed(hits):
        a=seq[i][1]; b=seq[i+len(want)-1][2]; s=s[:a]+new+s[b:]
    return s

# These additional interfaces are contracts to the routing integration, not
# claims about the unavailable fabric. They have no permissive defaults.
PORTS = '''
input logic FetchEnable_i,
input logic [31:0] FetchEpoch_i,
input logic FetchBindValid_i,
input logic [159:0] FetchBindData_i,
input logic [19:0] FetchBindToken_i,
input logic [31:0] DTSFetchEpoch_i,
input logic [19:0] DTSFetchToken_i,
input logic [6:0] DTSFetchIndex_i,
input logic WrDTSChipSelect_i, WrDTSWrite_i,
input logic [255:0] WrDTSWriteData_i,
output logic WrDTSWaitRequest_o,
input logic [31:0] WrDTSFetchEpoch_i,
input logic [19:0] WrDTSFetchToken_i,
input logic [6:0] WrDTSFetchIndex_i,
output logic WriteDescValid_o,
output logic [159:0] WriteDescData_o,
input logic WriteDescReady_i,
input logic FetchEndValid_i,
output logic FetchEndReady_o,
input logic [31:0] FetchEndEpoch_i,
input logic [19:0] FetchEndToken_i,
input logic FetchEndError_i,
input logic FetchAbortValid_i,
output logic FetchAbortReady_o,
input logic [31:0] FetchAbortEpoch_i,
input logic [19:0] FetchAbortToken_i,
output logic FetchIssueValid_o,
output logic [159:0] FetchIssueData_o,
output logic [7:0] FetchIssueFirstId_o,
output logic FetchFault_o,
output logic [7:0] FetchFaultReason_o,
output logic [31:0] FetchFaultEpoch_o,
output logic [19:0] FetchFaultToken_o,
output logic [7:0] FetchFaultIndex_o,
output logic FetchLocalErrorValid_o,
input logic FetchLocalErrorReady_i,
output logic [31:0] FetchLocalErrorEpoch_o,
output logic [19:0] FetchLocalErrorToken_o,
output logic [7:0] FetchLocalErrorReason_o, FetchLocalErrorCount_o,
'''
FIRST_PORTS = '''
input logic [7:0] WrDescFirstId_i,
output logic [7:0] WrDescFirstId_o,
'''

def accounting(s):
    # SystemVerilog variables must be declared before use in procedural and
    # connection expressions. Place the common TX block after the last legacy
    # declaration, before fetch-counter, register, and consumer references.
    s=tokens(s, 'logic [7:0] desc_controller_slave_address;',
      'logic [7:0] desc_controller_slave_address;\n`include "controller_tx_v4.svh"')
    s=tokens(s, 'else if (dma_tx_state[4] | WrDescTxAck_i)', 'else if (v4_fetch_fire)')
    # A fresh endpoint write supersedes the saved endpoint when it can be
    # applied directly. Otherwise that stale saved pointer replays next cycle.
    # Preserve the original pending_desc_id_wen priority over this clearing arm.
    s=tokens(s, 'else if (ep_last_pntr_from_pending_wen) pending_desc_id_stored <= 1\'b0;',
      'else if (ep_last_pntr_wen) pending_desc_id_stored <= 1\'b0;')
    s=tokens(s, 'assign register_ready_reg = (dcs_current_state[2] | dcs_current_state[3]);',
      '''assign register_ready_reg = (dcs_current_state[2] | dcs_current_state[3]) &&
        !(DCSWrite_i && desc_controller_slave_address!=8'h10 &&
          desc_controller_slave_address!=8'h18 && v4_config_busy);''')
    s=span(s, '/// state machine to send descriptors to controller to transfer DMA data',
           '/// Store the last desc ID being fetch', '')
    s=tokens(s, 'prev_desc_id_reg <= (current_desc_id == table_id_size_reg[7:0])? 8\'hFF : current_desc_id;',
       "prev_desc_id_reg <= (v4_last == v4_table_last)? 8'hFF : v4_last;", 2)
    s=tokens(s, 'current_dt_address_reg <= (current_desc_id == table_id_size_reg[7:0])? dt_desc_base[63:0] : (current_dt_address_reg + {sent_dt_size[7:0], 5\'h0});',
       "current_dt_address_reg <= (v4_last == v4_table_last)? v4_table_base : (v4_fetch_snapshot[63:0] + {v4_count,5'b0});", 2)
    s=tokens(s, 'desc_fetch_send & current_desc_id == table_id_size_reg[7:0]',
       'desc_fetch_send & v4_last == v4_table_last')
    s=tokens(s, 'WrDescTxAck_i & current_desc_id == table_id_size_reg[7:0]',
       'v4_fetch_fire & v4_last == v4_table_last')
    s=tokens(s, 'else if(WrDescTxAck_i)', 'else if(v4_fetch_fire)', 2)
    return s

def read_controller(raw):
    if sha(raw)!=CONTROLLER_SHA: raise ValueError('private v3 controller SHA256 mismatch')
    s=raw.decode()
    s=once(s,'module altpcie_dynamic_control_candidate_v3 #(',
           'module altpcie_dynamic_control_fetch_v4 #(')
    s=tokens(s,'input logic [159:0] WrDescTxData_i,',
       FIRST_PORTS+PORTS+'input logic [159:0] WrDescTxData_i,')
    s=tokens(s,'input logic FetchStatusReady_i,','output logic FetchStatusReady_o,')
    s=span(s, '// Candidate-v3 keeps wire version2.', ' /// decoding the address', '''
logic v3_fetch_valid;
logic [31:0] v3_fetch_word;
logic v2_status_accept;
assign v2_status_accept = DmaRxValid_i && DmaRxReady_o;
assign FetchStatusValid_o = v3_fetch_valid;
assign FetchStatusData_o = v3_fetch_word;
// synthesis translate_off
initial if (READ_CONTROL!=1 || DMA_WIDTH!=256)
  $fatal(1,"fetch-v4 read controller requires READ_CONTROL=1 DMA_WIDTH=256");
// synthesis translate_on
''')
    # Remove the two unused legacy observation registers, not just their readers.
    s=tokens(s,'logic [31:0] dma_status_reg;','')
    s=tokens(s,'logic dma_status_valid_reg;','')
    s=span(s,'// The Descriptor Data Table Interface 256-bit Interface',
       '/// DT fifo','`include "controller_consumer_v4.svh"\n')
    s=accounting(s)
    s=tokens(s,'dma_status_sink_v3 #', 'dma_status_sink_fetch_v4 #')
    s=tokens(s,'.fetch_ready(FetchStatusReady_i)', '.fetch_ready(v4_status_ready)')
    for old,new in [('StatusDiagnosticValid_o','v4_sink_diag_valid'),
                    ('StatusDiagnosticReady_i','v4_status_ready'),
                    ('StatusDiagnosticData_o','v4_sink_diag_word'),
                    ('StatusProtocolFault_o','v4_sink_fault'),
                    ('StatusProtocolFaultWord_o','v4_sink_fault_word')]:
        # Only sink connections, never replace new public port names.
        field={'StatusDiagnosticValid_o':'diagnostic_valid','StatusDiagnosticReady_i':'diagnostic_ready',
          'StatusDiagnosticData_o':'diagnostic_word','StatusProtocolFault_o':'protocol_fault',
          'StatusProtocolFaultWord_o':'fault_word'}[old]
        s=tokens(s,f'.{field}({old})',f'.{field}({new})')
    return s

def write_controller(raw):
    s=raw.decode()
    # Full licensed source is explicit input. Its untouched regions and original
    # status path must reproduce the exact private read derivative in the packet.
    check=C3.transform_controller(T.transform_controller(s),T)
    if sha(check.encode())!=CONTROLLER_SHA:
        raise ValueError('original controller does not regenerate the pinned v3 controller')
    s=once(s,'module altpcie_dynamic_control #(',
       'module altpcie_dynamic_control_write_v4 #(')
    s=tokens(s,'input logic [159:0] WrDescTxData_i );',
       FIRST_PORTS+'input logic [159:0] WrDescTxData_i );')
    s=span(s,'// The Descriptor Data Table Interface 256-bit Interface','/// DT fifo', '''
// This port is fed ONLY by the committed write-table copier in the pair wrapper.
assign dt_fifo_ok = dt_fifo_count<=250;
assign DTSWaitRequest_o = !Rstn_i || !dt_fifo_ok;
assign dt_fifo_data_in = DTSWriteData_i[159:0];
assign dt_fifo_wrreq_reg = DTSChipSelect_i && DTSWrite_i && !DTSWaitRequest_o;
assign dt_fifo_wrreq_reg1 = 1'b0;
assign v4_issue_ready = 1'b1; // write fetches use the independent Req/Ack channel
assign v4_tx_fault = 1'b0;
// synthesis translate_off
initial if (READ_CONTROL!=0 || DMA_WIDTH!=256)
  $fatal(1,"fetch-v4 write controller requires READ_CONTROL=0 DMA_WIDTH=256");
// synthesis translate_on
''')
    return accounting(s)

def owner():
    raw=(V3/'rtl/dma_owner_v3.sv').read_bytes()
    if sha(raw)!='1300a64ad152170defc7f3e25f541da897aac666364c4c9517472207576b33e3':
        raise ValueError('pinned v3 owner bytes differ')
    s=once(raw.decode(),'module dma_owner_v3 (','module dma_owner_fetch_v4 (')
    s=once(s,'output logic [3:0] descriptor_slot,',
      'output logic [3:0] descriptor_slot,\noutput logic [19:0] descriptor_token,')
    return once(s,'assign status_valid =', '''assign descriptor_token = {
  generation_q[descriptor_slot]==8'hff ? 8'h1 : generation_q[descriptor_slot]+8'h1,
  descriptor_slot, descriptor_id};
assign status_valid =''')

def engine(raw, manifest):
    m=json.loads(manifest.read_text())
    if (m.get('request_id') != C3.REQUEST or
        m.get('source_packet_sha256') != C3.REUSE_PACKET_SHA256 or
        m.get('wire_status_version') != 2 or
        m.get('production_contract_valid') is not False or
        m.get('outputs',{}).get('altpcieav_dma_rd_candidate_v3.sv')!=sha(raw)):
        raise ValueError('v3 engine manifest/output mismatch')
    s=once(raw.decode(),'module altpcieav_dma_rd_candidate_v3 # (',
       'module altpcieav_dma_rd_fetch_v4 # (')
    s=tokens(s,'output logic RdDmaAckConsumed_o,', '''
output logic RdDmaAckConsumed_o,
output logic FetchBindValid_o,
output logic [159:0] FetchBindData_o,
output logic [19:0] FetchBindToken_o,''')
    s=once(s,'`include "engine_v3_logic.svh"','`include "engine_fetch_v4.svh"')
    return s

def engine_include():
    s=(V3/'rtl/engine_v3_logic.svh').read_text()
    s=once(s,'dma_owner_v3 v2_owners (','dma_owner_fetch_v4 v2_owners (')
    s=once(s,'.descriptor_id(RdDmaRxData_i[153:146]), .descriptor_slot(v2_alloc_slot),',
      '.descriptor_id(RdDmaRxData_i[153:146]), .descriptor_slot(v2_alloc_slot),\n.descriptor_token(FetchBindToken_o),')
    return '''// Owner ADMISSION, not guessed controller-to-engine latency.
assign FetchBindValid_o = RdDmaRxValid_i && v2_desc_ready && RdDmaRxData_i[153];
assign FetchBindData_o = RdDmaRxData_i;
'''+s

def sink():
    s=(V3/'rtl/dma_status_sink_v3.sv').read_text()
    if sha(s.encode())!='c19c82a7b68d23a44ad525bb9eeba2ae94d060775d63026a59d039e880cd1e1e':
        raise ValueError('pinned v3 sink bytes differ')
    s=once(s,'module dma_status_sink_v3 #','module dma_status_sink_fetch_v4 #')
    s=once(s,'DIAGNOSTIC, FETCH_FENCE, RECEIPT','DIAGNOSTIC, RECEIPT')
    s=span(s,'      // The legacy controller consumer samples its ingress register on the',
      '      DIAGNOSTIC:', '''      // fetch_ready is the table's atomic executable-custody commit.
      FETCH: if (fetch_accept) state <= RECEIPT;
''')
    s=tokens(s,'$past(published_success && !active.word[7]) || $past(state == FETCH_FENCE)',
      '$past(published_success)')
    s=tokens(s,'''assert property (@(posedge clk) disable iff (!rstn)
      state == FETCH_FENCE |-> $past(fetch_accept));''','')
    return s

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--controller',required=True,type=Path)
    p.add_argument('--write-controller',type=Path)
    p.add_argument('--engine',type=Path)
    p.add_argument('--engine-manifest',type=Path)
    p.add_argument('--control-wrapper',type=Path)
    p.add_argument('--app-wrapper',type=Path)
    p.add_argument('--parent',type=Path)
    p.add_argument('--configured',type=Path)
    p.add_argument('--out',required=True,type=Path)
    a=p.parse_args()
    try:
        inputs=[x.resolve() for x in vars(a).values() if isinstance(x,Path) and x!=a.out]
        out=a.out.resolve()
        if out.exists() or any(out==x or x.is_relative_to(out) for x in inputs):
            raise ValueError('--out must be a new isolated directory')
        generated={'altpcie_dynamic_control_fetch_v4.sv':read_controller(a.controller.read_bytes()),
          'dma_owner_fetch_v4.sv':owner(),'dma_status_sink_fetch_v4.sv':sink(),
          'engine_fetch_v4.svh':engine_include()}
        if a.write_controller:
            generated['altpcie_dynamic_control_write_v4.sv']=write_controller(a.write_controller.read_bytes())
        if a.engine:
            if not a.engine_manifest: raise ValueError('--engine requires --engine-manifest')
            generated['altpcieav_dma_rd_fetch_v4.sv']=engine(a.engine.read_bytes(),a.engine_manifest)
        if any([a.control_wrapper,a.app_wrapper,a.parent,a.configured]):
            from shells import derive_shells
            generated.update(derive_shells(a))
        out.mkdir(parents=True)
        for name,value in generated.items(): (out/name).write_text(value)
        (out/'manifest.json').write_text(json.dumps({'request_id':REQUEST,'public_pin':PIN,
          'inputs':{str(x):sha(x.read_bytes()) for x in inputs},
          'outputs':{n:sha(v.encode()) for n,v in generated.items()},
          'production_contract_valid':False,'native_validation_performed':False,
          'driver_admission_enabled':False},indent=2)+'\n')
        print(out)
    except (OSError,ValueError,KeyError) as e:
        p.exit(2,f'REFUSED: {e}\n')

if __name__=='__main__': main()
