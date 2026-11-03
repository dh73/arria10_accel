# SPDX-License-Identifier: BSD-3-Clause
"""Source-pinned shell rewiring. Original vendor bytes remain local inputs."""
from pathlib import Path
import re
from build import PORTS, V3, T, load, once, tokens

CW=load(V3/'tools/build_control_wrapper.py','cw3')
AW=load(V3/'tools/build_app_wrapper.py','aw3')
PW=load(V3/'tools/build_parent_wrapper.py','pw3')
GW=load(V3/'tools/build_configured_wrapper.py','gw3')

INTERNAL={'WrDTSChipSelect_i','WrDTSWrite_i','WrDTSWriteData_i','WrDTSWaitRequest_o',
          'WriteDescValid_o','WriteDescData_o','WriteDescReady_i'}
BIND={'FetchBindValid_i','FetchBindData_i','FetchBindToken_i'}

def declarations():
    found=[]
    for match in re.finditer(r'(input|output)\s+logic\s+(\[[^\]]+\]\s*)?(.+?)(?=\b(?:input|output)\s+logic|\Z)', PORTS,re.S):
        direction,width,names=match.groups()
        for name in re.findall(r'\b\w+_[io]\b',names):
            if name not in INTERNAL: found.append((direction,width or '',name))
    return found

def ports(parent=False):
    return ''.join(f'\n{d} wire {w}Candidate{n},' for d,w,n in declarations()
                   if not parent or n not in BIND)+'\n'

def named_region(s,seq,opening):
    # Comments and quoted strings cannot contribute delimiter tokens. Preserve
    # the original byte offsets so unrelated connections remain byte-for-byte.
    a=seq[opening][2]; depth=1; p=opening+1
    while p<len(seq) and depth:
        depth+=(seq[p][0]=='(')-(seq[p][0]==')'); p+=1
    if depth: raise ValueError('unclosed named-argument list')
    closing=p-1; b=seq[closing][1]; result={}; p=opening+1
    while p<closing:
        if p+2>=closing or seq[p][0]!='.' or seq[p+2][0]!='(':
            raise ValueError('non-named argument')
        key=seq[p+1][0]; start=seq[p+2][2]; p+=3; depth=1
        while p<closing and depth:
            depth+=(seq[p][0]=='(')-(seq[p][0]==')'); p+=1
        if depth or key in result: raise ValueError('malformed/duplicate argument')
        result[key]=s[start:seq[p-1][1]].strip()
        if p<closing:
            if seq[p][0]!=',': raise ValueError('missing argument separator')
            p+=1
            if p==closing: raise ValueError('trailing argument separator')
    return a,b,result

def instance(s,name):
    seq=T._tokens(s)
    hits=[i for i in range(len(seq)-1) if seq[i][0]==name and seq[i+1][0]=='(']
    if len(hits)!=1: raise ValueError(f'nonunique instance {name}')
    return named_region(s,seq,hits[0]+1)

def parameter(s,module,key,value):
    seq=T._tokens(s)
    hits=[i for i in range(len(seq)-2)
          if [x[0] for x in seq[i:i+3]]==[module,'#','(']]
    if len(hits)!=1: raise ValueError(f'nonunique parameterized module {module}')
    a,b,existing=named_region(s,seq,hits[0]+2)
    body=s[a:b]
    if key in existing:
        body=tokens(body,f'.{key}({existing[key]})',f'.{key}({value})')
    else:
        body=f'.{key}({value})'+(',' if existing else '')+body
    return s[:a]+body+s[b:]

def change_instance(s,name,changes, additions):
    a,b,existing=instance(s,name); body=s[a:b]
    for key,value in changes.items():
        if key not in existing: raise ValueError(f'{name} lacks {key}')
        body=tokens(body,f'.{key}({existing[key]})',f'.{key}({value})')
    if set(additions)&set(existing): raise ValueError('new port already present')
    prefix=''.join(f'\n .{key}({value}),' for key,value in additions.items())
    return s[:a]+prefix+body+s[b:]

def control(raw):
    s=CW.transform(raw)
    s=once(s,'module dma_control_candidate_v3 #(', 'module dma_control_fetch_v4 #(')
    s=once(s,'input logic RdFetchStatusReady_i,','output logic RdFetchStatusReady_o,')
    s=tokens(s,'.FetchStatusReady_i(RdFetchStatusReady_i)',
               '.FetchStatusReady_o(RdFetchStatusReady_o)')
    s=once(s,'      input logic                                  Clk_i,',
       ports()+'      input logic                                  Clk_i,')
    _,_,wr=instance(s,'write_control')
    required=['DTSChipSelect_i','DTSWrite_i','DTSWriteData_i','DTSWaitRequest_o']
    if any(k not in wr for k in required): raise ValueError('write DTS mapping missing')
    add={n:'Candidate'+n for _,_,n in declarations()}
    add.update({'WrDTSChipSelect_i':wr['DTSChipSelect_i'],
      'WrDTSWrite_i':wr['DTSWrite_i'],'WrDTSWriteData_i':wr['DTSWriteData_i'],
      'WrDTSWaitRequest_o':wr['DTSWaitRequest_o'],
      'WriteDescValid_o':'copy_valid','WriteDescData_o':'copy_data',
      'WriteDescReady_i':'!copy_wait','WrDescFirstId_i':'write_first','WrDescFirstId_o':''})
    s=change_instance(s,'read_control',{},add)
    s=change_instance(s,'write_control',{
      'DTSChipSelect_i':'copy_valid','DTSWrite_i':'copy_valid',
      'DTSBurstCount_i':"5'd1",'DTSAddress_i':"8'd0",
      'DTSWriteData_i':"{96'b0,copy_data}",'DTSWaitRequest_o':'copy_wait'},
      {'WrDescFirstId_i':"8'd0",'WrDescFirstId_o':'write_first'})
    s=tokens(s,'altpcie_dynamic_control_candidate_v3 #', '''
wire copy_valid, copy_wait;
wire [159:0] copy_data;
wire [7:0] write_first;
altpcie_dynamic_control_fetch_v4 #''')
    s=tokens(s,'altpcie_dynamic_control #','altpcie_dynamic_control_write_v4 #')
    # Original write wrapper omitted DMA_WIDTH; supply the same qualified width.
    s=parameter(s,'altpcie_dynamic_control_write_v4','DMA_WIDTH','DMA_WIDTH')
    return s

APP_PORTS='''
output logic FetchBindValid_o,
output logic [159:0] FetchBindData_o,
output logic [19:0] FetchBindToken_o,
'''
def app(raw):
    s=AW.transform(raw)
    s=once(s,'module altpcieav_256_app_candidate_v3\n','module altpcieav_256_app_fetch_v4\n')
    s=once(s,'/// System Clock and Reset\n',APP_PORTS+'/// System Clock and Reset\n')
    s=tokens(s,'altpcieav_dma_rd_candidate_v3 #','altpcieav_dma_rd_fetch_v4 #')
    s=change_instance(s,'read_data_mover',{}, {n:n for n in
      ['FetchBindValid_o','FetchBindData_o','FetchBindToken_o']})
    return once(s,"     assign RdReceiptConsumed_o = 1'b0;",'''     assign FetchBindValid_o = 1'b0;
     assign FetchBindData_o = 160'b0;
     assign FetchBindToken_o = 20'b0;
     assign RdReceiptConsumed_o = 1'b0;''')

def parent(raw):
    s=PW.transform(raw)
    s=once(s,'module c10_receipt_parent_candidate_v3 # (','module c10_fetch_parent_v4 # (')
    s=once(s,'input wire CandidateRdFetchStatusReady_i,','output wire CandidateRdFetchStatusReady_o,')
    s=tokens(s,'.RdFetchStatusReady_i(CandidateRdFetchStatusReady_i)',
       '.RdFetchStatusReady_o(CandidateRdFetchStatusReady_o)')
    s=once(s,') (\n',') ('+ports(parent=True)+'\n')
    s=tokens(s,'dma_control_candidate_v3 #','dma_control_fetch_v4 #')
    s=tokens(s,'altpcieav_256_app_candidate_v3 #','altpcieav_256_app_fetch_v4 #')
    s=once(s,'wire candidate_rd_status_ready;', '''wire fetch_bind_valid;
wire [159:0] fetch_bind_data;
wire [19:0] fetch_bind_token;
wire candidate_rd_status_ready;''')
    add={'Candidate'+n:'Candidate'+n for _,_,n in declarations() if n not in BIND}
    add.update({'CandidateFetchBindValid_i':'fetch_bind_valid',
      'CandidateFetchBindData_i':'fetch_bind_data','CandidateFetchBindToken_i':'fetch_bind_token'})
    s=change_instance(s,'dma_control_0',{},add)
    return change_instance(s,'altpcieav_256_app',{}, {
      'FetchBindValid_o':'fetch_bind_valid','FetchBindData_o':'fetch_bind_data',
      'FetchBindToken_o':'fetch_bind_token'})

def configured(raw):
    s=GW.transform(raw)
    s=once(s,'module c10_configured_candidate_v3 (','module c10_configured_fetch_v4 ('+ports(parent=True))
    s=once(s,'input wire CandidateRdFetchStatusReady_i,','output wire CandidateRdFetchStatusReady_o,')
    s=tokens(s,'.CandidateRdFetchStatusReady_i(CandidateRdFetchStatusReady_i)',
       '.CandidateRdFetchStatusReady_o(CandidateRdFetchStatusReady_o)')
    s=tokens(s,'c10_receipt_parent_candidate_v3 #','c10_fetch_parent_v4 #')
    return change_instance(s,'dut',{}, {
      'Candidate'+n:'Candidate'+n for _,_,n in declarations() if n not in BIND})

def derive_shells(args):
    if args.control_wrapper and not args.write_controller:
        raise ValueError('--control-wrapper requires --write-controller')
    if args.app_wrapper and not args.engine:
        raise ValueError('--app-wrapper requires --engine and --engine-manifest')
    if args.parent and not (args.control_wrapper and args.app_wrapper):
        raise ValueError('--parent requires both containing wrappers')
    if args.configured and not args.parent: raise ValueError('--configured requires --parent')
    result={}
    for path,fn,name in [(args.control_wrapper,control,'dma_control_fetch_v4.sv'),
      (args.app_wrapper,app,'altpcieav_256_app_fetch_v4.sv'),
      (args.parent,parent,'c10_fetch_parent_v4.sv'),
      (args.configured,configured,'c10_configured_fetch_v4.sv')]:
        if path: result[name]=fn(path.read_bytes())
    return result
