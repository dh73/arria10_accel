#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Build a return-fabric candidate from exact v4 source bytes.

Transformations reject source-hash or named-port mismatches.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import producer as P
V4=P.V4
PIN='2c7b4e9a23b4daed230bc7aa41691982128eb7d1'
FORMAT='dma-fetch-return-v5'
CONSUMER_SHA='3a3b013f0be6df7d72aaea973984cecbd9dcce020307fec3fe40259da549ab11'
ROUTE_SHA='f9d6f16b82a4892d3c7f428971a6b3f7e0e572b1d02f32099cb40cdda488e8a7'
FAULT_PORTS='''
input logic FetchFabricFault_i,
input logic [7:0] FetchFabricReason_i,
input logic [31:0] FetchFabricEpoch_i,
input logic [19:0] FetchFabricToken_i,
input logic [7:0] FetchFabricIndex_i,
'''

def consumer():
    raw=(ROOT.parent/'dma-fetch-v4/rtl/dma_fetch_commit_v4.sv').read_bytes()
    if P.sha(raw)!=CONSUMER_SHA: raise ValueError('pinned owned v4 consumer SHA256 mismatch')
    s=V4.tokens(raw.decode(),'module dma_fetch_commit_v4 #(',
                'module dma_fetch_commit_return_v5 #(')
    s=V4.tokens(s,'input logic clk, rstn, enable,','''
input logic fabric_fault,
input logic [7:0] fabric_reason,
input logic [31:0] fabric_epoch,
input logic [19:0] fabric_token,
input logic [7:0] fabric_index,
input logic clk, rstn, enable,''')
    s=V4.tokens(s,'!fault && free_bank>=0 && !duplicate_id && issue_shape;',
      '!fault && !fabric_fault && free_bank>=0 && !duplicate_id && issue_shape;')
    # Registered fault is too late for a same-edge owner success. This veto
    # participates in the existing bad_event gate, which also stops new emits.
    return V4.tokens(s,'if (issue_offer && !issue_shape) begin','''
if (fabric_fault) begin
  bad_event=1; reason_now=fabric_reason; token_now=fabric_token;
  epoch_now=fabric_epoch; index_now=fabric_index;
end else if (issue_offer && !issue_shape) begin''')

def controller(raw):
    s=V4.read_controller(raw)
    s=V4.tokens(s,'module altpcie_dynamic_control_fetch_v4 #(',
                  'module altpcie_dynamic_control_fetch_return_v5 #(')
    s=V4.tokens(s,'input logic FetchEnable_i,',FAULT_PORTS+'input logic FetchEnable_i,')
    return V4.once(s,'`include "controller_consumer_v4.svh"',
                     '`include "controller_consumer_return_v5.svh"')

def controller_include():
    s=(ROOT.parent/'dma-fetch-v4/rtl/controller_consumer_v4.svh').read_text()
    s=V4.tokens(s,'dma_fetch_commit_v4 fetch_consumer (',
      'dma_fetch_commit_return_v5 fetch_consumer (')
    return V4.tokens(s,'.clk(Clk_i), .rstn(Rstn_i), .enable(FetchEnable_i),', '''
.fabric_fault(FetchFabricFault_i), .fabric_reason(FetchFabricReason_i),
.fabric_epoch(FetchFabricEpoch_i), .fabric_token(FetchFabricToken_i),
.fabric_index(FetchFabricIndex_i),
.clk(Clk_i), .rstn(Rstn_i), .enable(FetchEnable_i),''')

def derive(engine_raw):
    result={
      'altpcieav_dma_rd_fetch_return_v5.sv':P.engine(engine_raw),
      'dma_owner_fetch_return_v5.sv':P.owner(),
      'engine_fetch_return_v5.svh':P.engine_include(),
      'engine_v2_declarations.svh':P.declarations(),
      'dma_fetch_commit_return_v5.sv':consumer(),
      'dma_status_sink_fetch_v4.sv':V4.sink(),
      'controller_consumer_return_v5.svh':controller_include(),
      'controller_tx_v4.svh':(ROOT.parent/'dma-fetch-v4/rtl/controller_tx_v4.svh').read_text(),
    }
    for path in (ROOT/'rtl').glob('*.sv*'): result[path.name]=path.read_text()
    return result

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine',type=Path,required=True,help='exact unmodified v4 engine')
    ap.add_argument('--out',type=Path,required=True,help='new isolated directory')
    ap.add_argument('--controller',type=Path,help='exact v3 read controller accepted by v4')
    ap.add_argument('--write-controller',type=Path,help='original dynamic controller')
    ap.add_argument('--control-wrapper',type=Path)
    ap.add_argument('--app-wrapper',type=Path)
    ap.add_argument('--parent',type=Path)
    ap.add_argument('--configured',type=Path)
    ap.add_argument('--route',type=Path,help='unchanged external arria10_native_dma_route.sv')
    args=ap.parse_args()
    try:
        paths=[v.resolve() for k,v in vars(args).items() if k!='out' and isinstance(v,Path)]
        out=args.out.resolve()
        if out.exists() or any(out==p or out.is_relative_to(p) or p.is_relative_to(out) for p in paths):
            raise ValueError('--out must be new and disjoint from all source inputs')
        if out.is_relative_to(ROOT.parent.parent):
            raise ValueError('generated derivatives must stay outside the repository')
        generated=derive(args.engine.read_bytes())
        if args.controller:
            generated['altpcie_dynamic_control_fetch_return_v5.sv']=controller(args.controller.read_bytes())
        if args.write_controller:
            generated['altpcie_dynamic_control_write_v4.sv']=V4.write_controller(args.write_controller.read_bytes())
        shells=[args.control_wrapper,args.app_wrapper,args.parent,args.configured]
        if any(shells):
            if not all(shells+[args.controller,args.write_controller,args.route]):
                raise ValueError('full wiring requires --controller --write-controller --control-wrapper '
                                 '--app-wrapper --parent --configured --route; partial shells are refused')
            import shells as S
            generated.update(S.derive(args))
        if args.route:
            raw=args.route.read_bytes()
            if P.sha(raw)!=ROUTE_SHA: raise ValueError('unchanged external route SHA256 mismatch')
            generated['arria10_native_dma_route.sv']=raw.decode()
        # Finish every transformation before creating any output directory.
        report={'format':FORMAT,'base_commit':PIN,
          'original_inputs':{str(p):P.sha(p.read_bytes()) for p in paths},
          'verified_seed_sha256':{'engine':P.ENGINE_SHA,'owner':P.OWNER_SHA,
            'include':P.INCLUDE_SHA,'declarations':P.DECLARATIONS_SHA,'consumer':CONSUMER_SHA},
          'outputs':{n:P.sha(s.encode()) for n,s in generated.items()},
          'containing_shell_generated':all(bool(x) for x in shells),
          'driver_enabled':False,'production_contract_valid':False,
          'native_vcs_executed':False,'lean_executed':False,'rtl_refinement_proved':False}
        out.mkdir(parents=True)
        for n,s in generated.items(): (out/n).write_text(s)
        (out/'source_manifest.json').write_text(json.dumps(report,indent=2)+'\n')
        print(f'Generated return-fabric candidate (not executed): {out}')
        return 0
    except (OSError,ValueError,KeyError) as e:
        ap.exit(2,f'REFUSED: {e}\n')

if __name__=='__main__': raise SystemExit(main())
