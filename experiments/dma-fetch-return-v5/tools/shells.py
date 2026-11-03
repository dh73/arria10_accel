# SPDX-License-Identifier: BSD-3-Clause
"""Actual containing wiring, derived from the originals pinned by v4/v3.

The table path bypasses untagged Avalon posting/arbitration. The native engine
sees waitrequest from the actual quarantined DTS destination. The payload and
DCM paths remain on their existing connections. No hierarchy/port is guessed:
all old instance expressions are parsed from the hash-checked supplied files.
"""
from __future__ import annotations
import sys
import producer as P
V4=P.V4
old=sys.modules.get('build')
sys.modules['build']=V4
try: S4=V4.load(V4.ROOT/'tools/shells.py','pinned_v4_shells')
finally:
    if old is None: del sys.modules['build']
    else: sys.modules['build']=old
tokens=V4.tokens

APP_PORTS='''
input logic FetchEnable_i, FetchConsumerFault_i,
input logic [31:0] FetchEpoch_i,
output wire [1:0] FetchDTSWrite_o,
output wire [1:0][255:0] FetchDTSData_o,
output wire [1:0][31:0] FetchDTSEpoch_o,
output wire [1:0][19:0] FetchDTSToken_o,
output wire [1:0][6:0] FetchDTSIndex_o,
input wire [1:0] FetchDTSWaitRequest_i,
output wire FetchEndValid_o,
input wire FetchEndReady_i,
output wire [31:0] FetchEndEpoch_o,
output wire [19:0] FetchEndToken_o,
output wire FetchEndError_o,
output wire FetchFabricFault_o,
output wire [7:0] FetchFabricReason_o,
output wire [31:0] FetchFabricEpoch_o,
output wire [19:0] FetchFabricToken_o,
output wire [7:0] FetchFabricIndex_o,
output wire [63:0] FetchFabricAddress_o,
'''
CONTROL_PORTS='''
input wire [1:0] ReturnDTSWrite_i,
input wire [1:0][255:0] ReturnDTSData_i,
output wire [1:0] ReturnDTSWaitRequest_o,
input wire ReturnFabricFault_i,
input wire [7:0] ReturnFabricReason_i,
input wire [31:0] ReturnFabricEpoch_i,
input wire [19:0] ReturnFabricToken_i,
input wire [7:0] ReturnFabricIndex_i,
output logic ReturnLegacyFault_o,
'''
RETURN_INTERNAL={
 'DTSFetchEpoch_i','DTSFetchToken_i','DTSFetchIndex_i',
 'WrDTSFetchEpoch_i','WrDTSFetchToken_i','WrDTSFetchIndex_i',
 'FetchEndValid_i','FetchEndReady_o','FetchEndEpoch_i','FetchEndToken_i','FetchEndError_i'}

def require(args,names,where):
    missing={name for name in names if name not in args or not args[name].strip()}
    if missing: raise ValueError(f'{where} lacks actual named ports {sorted(missing)}')

def control(raw):
    s=S4.control(raw)
    s=tokens(s,'module dma_control_fetch_v4 #(', 'module dma_control_fetch_return_v5 #(')
    s=tokens(s,'input logic Clk_i,',CONTROL_PORTS+'input logic Clk_i,')
    _,_,r=S4.instance(s,'read_control')
    need=['Clk_i','Rstn_i','DTSChipSelect_i','DTSWrite_i','DTSWriteData_i','DTSWaitRequest_o',
          'WrDTSChipSelect_i','WrDTSWrite_i','WrDTSWriteData_i','WrDTSWaitRequest_o']
    require(r,need,'read_control')
    legacy=f'''
wire return_legacy_active=({r['DTSChipSelect_i']} && {r['DTSWrite_i']}) ||
                          ({r['WrDTSChipSelect_i']} && {r['WrDTSWrite_i']});
// Untagged ingress cannot acknowledge executable descriptor writes.
assign {r['DTSWaitRequest_o']}=1'b1;
assign {r['WrDTSWaitRequest_o']}=1'b1;
always_ff @(posedge {r['Clk_i']} or negedge {r['Rstn_i']})
  if(!{r['Rstn_i']}) ReturnLegacyFault_o<=0;
  else if(return_legacy_active) ReturnLegacyFault_o<=1;
'''
    s=tokens(s,'altpcie_dynamic_control_fetch_v4 #',
             legacy+'\naltpcie_dynamic_control_fetch_return_v5 #')
    return S4.change_instance(s,'read_control',{
      'DTSChipSelect_i':'ReturnDTSWrite_i[0]','DTSWrite_i':'ReturnDTSWrite_i[0]',
      'DTSWriteData_i':'ReturnDTSData_i[0]','DTSWaitRequest_o':'ReturnDTSWaitRequest_o[0]',
      'WrDTSChipSelect_i':'ReturnDTSWrite_i[1]','WrDTSWrite_i':'ReturnDTSWrite_i[1]',
      'WrDTSWriteData_i':'ReturnDTSData_i[1]','WrDTSWaitRequest_o':'ReturnDTSWaitRequest_o[1]'}, {
      'FetchFabricFault_i':'ReturnFabricFault_i || ReturnLegacyFault_o || return_legacy_active',
      'FetchFabricReason_i':"return_legacy_active || ReturnLegacyFault_o ? 8'he1 : ReturnFabricReason_i",
      'FetchFabricEpoch_i':'return_legacy_active || ReturnLegacyFault_o ? CandidateFetchEpoch_i : ReturnFabricEpoch_i',
      'FetchFabricToken_i':"return_legacy_active || ReturnLegacyFault_o ? 20'b0 : ReturnFabricToken_i",
      'FetchFabricIndex_i':'ReturnFabricIndex_i'})

def app(raw):
    s=S4.app(raw)
    if s.count('//DMA write data mover\n') != 2:
        raise ValueError('expected both native write-mover branches')
    old_tail=s.rsplit('//DMA write data mover\n', 1)
    if len(old_tail)!=2: raise ValueError('missing exact write-mover preservation boundary')
    s=tokens(s,'module altpcieav_256_app_fetch_v4', 'module altpcieav_256_app_fetch_return_v5')
    s=tokens(s,'output logic FetchBindValid_o,', APP_PORTS+'output logic FetchBindValid_o,')
    _,_,r=S4.instance(s,'read_data_mover')
    require(r,['Clk_i','Rstn_i','RdDmaWrite_o','RdDmaAddress_o','RdDmaWriteData_o',
      'RdDmaBurstCount_o','RdDmaWriteEnable_o','RdDmaWaitRequest_i'],'read_data_mover')
    wiring=f'''
wire return_raw_write,return_raw_wait;
wire [63:0] return_raw_address,return_raw_base;
wire [255:0] return_raw_data;
wire [31:0] return_raw_be,return_raw_epoch;
wire [19:0] return_raw_token;
wire [7:0] return_raw_count;
wire [4:0] return_raw_burst;
wire return_engine_fault,return_route_fault,return_route_fault_now;
wire [7:0] return_engine_reason,return_engine_tag,return_route_reason,return_route_reason_now;
wire [31:0] return_engine_epoch,return_route_epoch;
wire [19:0] return_engine_token,return_route_token;
wire [63:0] return_route_address,return_beat_address;
assign FetchFabricFault_o=return_route_fault_now || return_engine_fault;
assign FetchFabricReason_o=return_route_fault_now ? (8'h40 | return_route_reason_now) :
                                                                  (8'h80 | return_engine_reason);
assign FetchFabricEpoch_o=return_route_fault_now ?
  return_route_epoch : return_engine_epoch;
assign FetchFabricToken_o=return_route_fault_now ?
  return_route_token : return_engine_token;
assign FetchFabricIndex_o=return_route_fault_now ? 8'hff : return_engine_tag;
assign FetchFabricAddress_o=return_route_address;
dma_fetch_return_route_v5 return_route (
 .clk({r['Clk_i']}),.rstn({r['Rstn_i']}),.enable(FetchEnable_i),.epoch(FetchEpoch_i),
 .inhibit(return_engine_fault || FetchConsumerFault_i),
 .s_address(return_raw_address),.s_write(return_raw_write),.s_data(return_raw_data),
 .s_byteenable(return_raw_be),.s_burstcount(return_raw_burst),
 .s_epoch(return_raw_epoch),.s_token(return_raw_token),.s_base(return_raw_base),.s_count(return_raw_count),
 .s_waitrequest(return_raw_wait),
 .payload_address({r['RdDmaAddress_o']}),.payload_write({r['RdDmaWrite_o']}),
 .payload_data({r['RdDmaWriteData_o']}),.payload_byteenable({r['RdDmaWriteEnable_o']}),
 .payload_burstcount({r['RdDmaBurstCount_o']}),.payload_waitrequest({r['RdDmaWaitRequest_i']}),
 .dts_write(FetchDTSWrite_o),.dts_data(FetchDTSData_o),.dts_epoch(FetchDTSEpoch_o),
 .dts_token(FetchDTSToken_o),.dts_index(FetchDTSIndex_o),.dts_waitrequest(FetchDTSWaitRequest_i),
 .fault_now(return_route_fault_now),.fault(return_route_fault),.fault_reason(return_route_reason),
 .fault_epoch(return_route_epoch),.fault_token(return_route_token),.fault_address(return_route_address),
 .reason_now(return_route_reason_now),.beat_address(return_beat_address),.accept(),.busy());
'''
    s=tokens(s,'altpcieav_dma_rd_fetch_v4 #',wiring+'\naltpcieav_dma_rd_fetch_return_v5 #')
    s=S4.parameter(s,'altpcieav_dma_rd_fetch_return_v5','RDDMA_AVL_ADDR_WIDTH','64')
    s=S4.change_instance(s,'read_data_mover',{
      'RdDmaWrite_o':'return_raw_write','RdDmaAddress_o':'return_raw_address',
      'RdDmaWriteData_o':'return_raw_data','RdDmaWriteEnable_o':'return_raw_be',
      'RdDmaBurstCount_o':'return_raw_burst','RdDmaWaitRequest_i':'return_raw_wait'}, {
      'FetchEnable_i':'FetchEnable_i','FetchEpoch_i':'FetchEpoch_i',
      'ReturnEpoch_o':'return_raw_epoch','ReturnToken_o':'return_raw_token',
      'ReturnBase_o':'return_raw_base','ReturnCount_o':'return_raw_count',
      'FetchEndValid_o':'FetchEndValid_o','FetchEndReady_i':'FetchEndReady_i',
      'FetchEndEpoch_o':'FetchEndEpoch_o','FetchEndToken_o':'FetchEndToken_o','FetchEndError_o':'FetchEndError_o',
      'ReturnRouteFault_i':'return_route_fault_now || FetchConsumerFault_i',
      'ReturnFault_o':'return_engine_fault','ReturnFaultEpoch_o':'return_engine_epoch',
      'ReturnFaultToken_o':'return_engine_token','ReturnFaultReason_o':'return_engine_reason',
      'ReturnFaultTag_o':'return_engine_tag'})
    # Same inactive elaboration branch as the original v4 admission ports.
    inactive='''
assign FetchDTSWrite_o='0; assign FetchDTSData_o='0; assign FetchDTSEpoch_o='0;
assign FetchDTSToken_o='0; assign FetchDTSIndex_o='0;
assign FetchEndValid_o=0; assign FetchEndEpoch_o=0; assign FetchEndToken_o=0; assign FetchEndError_o=0;
assign FetchFabricFault_o=0; assign FetchFabricReason_o=0; assign FetchFabricEpoch_o=0;
assign FetchFabricToken_o=0; assign FetchFabricIndex_o=0; assign FetchFabricAddress_o=0;
'''
    s=tokens(s,"assign FetchBindValid_o = 1'b0;", inactive+"assign FetchBindValid_o = 1'b0;")
    if s.rsplit('//DMA write data mover\n', 1)[1]!=old_tail[1]:
        raise ValueError('unrelated D2H write mover/downstream bytes changed')
    return s

WIRES='''
wire [1:0] return_dts_write,return_dts_wait;
wire [1:0][255:0] return_dts_data;
wire [1:0][31:0] return_dts_epoch;
wire [1:0][19:0] return_dts_token;
wire [1:0][6:0] return_dts_index;
wire return_end_valid,return_end_ready,return_end_error,return_fabric_fault;
wire [31:0] return_end_epoch,return_fabric_epoch;
wire [19:0] return_end_token,return_fabric_token;
wire [7:0] return_fabric_reason,return_fabric_index;
'''
RETURNS={
 'DTSFetchEpoch_i':'return_dts_epoch[0]','DTSFetchToken_i':'return_dts_token[0]',
 'DTSFetchIndex_i':'return_dts_index[0]','WrDTSFetchEpoch_i':'return_dts_epoch[1]',
 'WrDTSFetchToken_i':'return_dts_token[1]','WrDTSFetchIndex_i':'return_dts_index[1]',
 'FetchEndValid_i':'return_end_valid','FetchEndReady_o':'return_end_ready',
 'FetchEndEpoch_i':'return_end_epoch','FetchEndToken_i':'return_end_token','FetchEndError_i':'return_end_error'}
PARENT_PORTS='''
output wire CandidateReturnLegacyFault_o,
output wire [63:0] CandidateReturnFaultAddress_o,
'''

def remove_external_returns(s):
    for direction,width,name in S4.declarations():
        if name in RETURN_INTERNAL:
            s=tokens(s,f'{direction} wire {width}Candidate{name},','')
    return s

def parent(raw):
    s=remove_external_returns(S4.parent(raw))
    s=tokens(s,'module c10_fetch_parent_v4 # (','module c10_fetch_parent_return_v5 # (')
    s=tokens(s,'input wire CandidateFetchEnable_i,',PARENT_PORTS+'input wire CandidateFetchEnable_i,')
    s=tokens(s,'wire fetch_bind_valid;',WIRES+'\nwire fetch_bind_valid;')
    s=tokens(s,'dma_control_fetch_v4 #','dma_control_fetch_return_v5 #')
    s=tokens(s,'altpcieav_256_app_fetch_v4 #','altpcieav_256_app_fetch_return_v5 #')
    s=S4.change_instance(s,'dma_control_0',{'Candidate'+k:v for k,v in RETURNS.items()}, {
      'ReturnDTSWrite_i':'return_dts_write','ReturnDTSData_i':'return_dts_data',
      'ReturnDTSWaitRequest_o':'return_dts_wait','ReturnFabricFault_i':'return_fabric_fault',
      'ReturnFabricReason_i':'return_fabric_reason','ReturnFabricEpoch_i':'return_fabric_epoch',
      'ReturnFabricToken_i':'return_fabric_token','ReturnFabricIndex_i':'return_fabric_index',
      'ReturnLegacyFault_o':'CandidateReturnLegacyFault_o'})
    return S4.change_instance(s,'altpcieav_256_app',{}, {
      'FetchEnable_i':'CandidateFetchEnable_i','FetchEpoch_i':'CandidateFetchEpoch_i',
      'FetchConsumerFault_i':'CandidateFetchFault_o || CandidateReturnLegacyFault_o',
      'FetchDTSWrite_o':'return_dts_write','FetchDTSData_o':'return_dts_data',
      'FetchDTSEpoch_o':'return_dts_epoch','FetchDTSToken_o':'return_dts_token',
      'FetchDTSIndex_o':'return_dts_index','FetchDTSWaitRequest_i':'return_dts_wait',
      'FetchEndValid_o':'return_end_valid','FetchEndReady_i':'return_end_ready',
      'FetchEndEpoch_o':'return_end_epoch','FetchEndToken_o':'return_end_token','FetchEndError_o':'return_end_error',
      'FetchFabricFault_o':'return_fabric_fault','FetchFabricReason_o':'return_fabric_reason',
      'FetchFabricEpoch_o':'return_fabric_epoch','FetchFabricToken_o':'return_fabric_token',
      'FetchFabricIndex_o':'return_fabric_index','FetchFabricAddress_o':'CandidateReturnFaultAddress_o'})

def configured(raw):
    s=remove_external_returns(S4.configured(raw))
    s=tokens(s,'module c10_configured_fetch_v4 (','module c10_configured_fetch_return_v5 ('+PARENT_PORTS)
    s=tokens(s,'c10_fetch_parent_v4 #','c10_fetch_parent_return_v5 #')
    # Remove now-internal connections rather than retaining an unconnected input.
    a,b,args=S4.instance(s,'dut');body=s[a:b]
    for name in RETURN_INTERNAL:
        key='Candidate'+name
        require(args,[key],'configured dut')
        body=tokens(body,f'.{key}({args[key]}),','')
    s=s[:a]+body+s[b:]
    return S4.change_instance(s,'dut',{}, {
      'CandidateReturnLegacyFault_o':'CandidateReturnLegacyFault_o',
      'CandidateReturnFaultAddress_o':'CandidateReturnFaultAddress_o'})

def derive(args):
    return {'dma_control_fetch_return_v5.sv':control(args.control_wrapper.read_bytes()),
      'altpcieav_256_app_fetch_return_v5.sv':app(args.app_wrapper.read_bytes()),
      'c10_fetch_parent_return_v5.sv':parent(args.parent.read_bytes()),
      'c10_configured_fetch_return_v5.sv':configured(args.configured.read_bytes())}
