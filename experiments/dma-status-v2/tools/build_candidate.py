#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Generate a separate candidate from the exact supplied packet/source.

No input is modified. Full read-engine/FIFO token equality is required. Only
the supplied controller regions are transformed; the omitted regions remain
explicit acceptance gates recorded in source_manifest.json.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
from controller_transform import _tokens, _locate, _replace, controller_audit, transform_controller

PACKET_SHA256 = '1b6eb7ecffd7758ca5d0c1e12a29fe9036dc806428137fc5e2f3d87222c988f5'

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def token_values(s: str) -> list[str]:
    return [t[0] for t in _tokens(s)]

def section(packet: str, first: str, last: str) -> str:
    if packet.count(first) != 1 or packet.count(last) != 1:
        raise ValueError(f'packet section ambiguous: {first!r}')
    return packet.split(first, 1)[1].split(last, 1)[0]

def cut(s: str, first: str, last: str, new: str, name: str) -> str:
    a, _ = _locate(s, first, name + ' start')
    b, _ = _locate(s, last, name + ' end')
    if b <= a:
        raise ValueError(f'{name}: reversed boundary')
    return s[:a] + new + s[b:]

def replace_controls(s: str) -> str:
    seq = _tokens(s)
    wanted = token_values('else if(RdDMACntrlLoad_i)')
    values = [x[0] for x in seq]
    matches = [i for i in range(len(values)-len(wanted)+1)
               if values[i:i+len(wanted)] == wanted]
    if len(matches) != 3:
        raise ValueError('expected exactly three supplied control-load guards')
    for i in reversed(matches):
        s = s[:seq[i][1]] + 'else if(v2_control_load)' + s[seq[i+len(wanted)-1][2]:]
    return s

def transform_engine(source: str) -> str:
    # Edit a COPY of the original, preserving its license and untouched comments.
    s = _replace(source, 'module altpcieav_dma_rd # (',
                 'module altpcieav_dma_rd_candidate_v2 # (', 'engine module')
    s = _replace(s, 'input logic [11:0] ko_cpl_spc_data );', '''
input logic [11:0] ko_cpl_spc_data,
input logic RdDmaTxReady_i,
input logic RdDmaAckValid_i,
input logic [31:0] RdDmaAckData_i,
output logic RdDMACntrlReady_o,
output logic ContractFault_o
);
`include "engine_v2_declarations.svh"
''', 'engine ports')
    s = _replace(s, 'logic [RDDMA_RXDATA_WIDTH-1:0] desc_head;',
                 'logic [RDDMA_RXDATA_WIDTH+3:0] desc_head;', 'descriptor head width')
    s = _replace(s, 'logic [RDDMA_RXDATA_WIDTH-1:0] desc_fifo_wrdat;',
                 'logic [RDDMA_RXDATA_WIDTH+3:0] desc_fifo_wrdat;', 'descriptor data width')
    s = _replace(s, '.FIFO_DEPTH(6), .DATA_WIDTH(RDDMA_RXDATA_WIDTH)',
                 '.FIFO_DEPTH(6), .DATA_WIDTH(RDDMA_RXDATA_WIDTH+4)', 'descriptor fifo width')
    s = _replace(s, '.srst(flush_all_desc & RdDMACntrlLoad_i)',
                 ".srst(1'b0)", 'retain flushed identities')
    s = _replace(s, 'assign desc_fifo_wrreq = RdDmaRxValid_i;',
                 'assign desc_fifo_wrreq = RdDmaRxValid_i && RdDmaRxReady_o;', 'descriptor handshake')
    s = _replace(s, 'assign desc_fifo_wrdat = RdDmaRxData_i;',
                 'assign desc_fifo_wrdat = {v2_alloc_slot, RdDmaRxData_i};', 'descriptor owner')
    s = _replace(s, "assign RdDmaRxReady_o = desc_fifo_count < 4'h3;",
                 'assign RdDmaRxReady_o = v2_desc_ready;', 'descriptor ready')
    s = replace_controls(s)
    s = _replace(s, 'assign cur_dma_pause = RdDMACntrlData_i[0];',
                 'assign cur_dma_pause = RdDMACntrlData_i[0] && !RdDMACntrlData_i[1];',
                 'resume overrides pause')
    s = cut(s, 'always_comb\nbegin\ncase(rd_dma_state)', 'assign rd_idle_state', '''
always_comb begin
  rd_dma_nxt_state = rd_dma_state;
  if (v2_current_valid && v2_stop_issue) begin
    rd_dma_nxt_state = RD_IDLE;
  end else case (rd_dma_state)
    RD_IDLE: if (rd_pop_desc_state && !v2_head_drop) rd_dma_nxt_state = RD_PIPE;
    RD_PIPE, RD_LD_SUB_DESC, RD_WAIT_TAG:
      if (cur_dma_pause_reg) rd_dma_nxt_state = RD_PAUSE;
      else if (tag_available_reg && cpl_header_available && cpl_data_available)
        rd_dma_nxt_state = RD_ARB_REQ;
      else rd_dma_nxt_state = RD_WAIT_TAG;
    RD_ARB_REQ:
      if (cur_dma_pause_reg) rd_dma_nxt_state = RD_PAUSE;
      else if (RdDMmaArbGranted_i && tx_fifo_ok && tag_available_reg)
        rd_dma_nxt_state = RD_SEND;
    RD_SEND:
      if (last_rd_segment) rd_dma_nxt_state = RD_CHECK_SUB_DESC;
      else if (cur_dma_pause_reg) rd_dma_nxt_state = RD_PAUSE;
      else if (tag_available_reg && cpl_header_available && cpl_data_available)
        rd_dma_nxt_state = RD_ARB_REQ;
      else rd_dma_nxt_state = RD_WAIT_TAG;
    RD_PAUSE:
      if (!cur_dma_pause_reg || cur_dma_resume_reg) rd_dma_nxt_state = RD_WAIT_TAG;
    RD_CHECK_SUB_DESC:
      rd_dma_nxt_state = last_sub_desc_reg ? RD_IDLE : RD_LD_SUB_DESC;
    default: rd_dma_nxt_state = RD_IDLE;
  endcase
end
''', 'issuer FSM')
    s = _replace(s, '''assign rd_pop_desc_state = rd_dma_state[0] & ~desc_fifo_empty &
 (desc_outstanding_reads_queue_fifo_ok | small_desc_size) & rd_status_fifo_count <= 5'h4;''', '''
assign rd_pop_desc_state = rd_dma_state[0] && !desc_fifo_empty &&
  (v2_head_drop || (!ContractFault_o && !v2_external_fault &&
                   !cur_dma_pause_reg && !v2_control_load));''', 'descriptor start/drop')
    s = _replace(s, 'assign rd_header_state = rd_dma_state[3];',
                 'assign rd_header_state = rd_dma_state[3] && !v2_stop_issue;', 'actual request issue')
    s = _replace(s, "else if(tag_fifo_rdreq) rd_tag_reg <= {{(8-NUM_TAG_WIDTH){1'b0}}, tag[NUM_TAG_WIDTH-1:0]};",
                 "else if(rd_arb_req_state) rd_tag_reg <= {{(8-NUM_TAG_WIDTH){1'b0}}, tag[NUM_TAG_WIDTH-1:0]};", 'tag peek')
    s = _replace(s, 'assign tag_fifo_rdreq = arbiter_req_rise;',
                 'assign tag_fifo_rdreq = rd_header_state;', 'consume issued tag')
    s = cut(s, 'generate if(EXTENDED_TAG_ENABLE == 1)\nassign valid_cpl_available',
            'always_comb\nbegin\ncase(rd_cpl_state)', '''
assign valid_cpl_available = !v2_bad_header && !rx_fifo_empty && rx_sop &&
  is_cpl_wd && avmmwr_fifo_ok && !ContractFault_o;
''', 'completion owner guard')
    s = _replace(s, '''(rdcpl_idle_state & (is_cpl_wd & rx_sop & cpl_tag <= NUM_TAG-1 & ~rx_fifo_empty) & ~latch_header_reg2)''',
                 '(rdcpl_idle_state & valid_cpl_available & ~latch_header_reg2)', 'completion pop guard')
    s = cut(s, "always_ff @ (posedge Clk_i or negedge Rstn_i)\nbegin\nif(~Rstn_i)\nbegin\nrd_tx_valid_reg <= 1'b0;",
            'assign RxFifoRdReq_o', '''
assign RdDMAStatus_o = {23'b0, ContractFault_o, cur_desc_id_reg};
''', 'old event encoder')
    s = cut(s, "always_ff @(posedge Clk_i or negedge Rstn_i) begin if(~Rstn_i) counter_id <= 6'h0;",
            'always_ff @(posedge Clk_i) begin avmmwr_data_reg', '', 'legacy descriptor ledger')
    s = _replace(s, 'logic [64+7:0] avmmwr_cmd;',
                 'logic [74:0] avmmwr_cmd;', 'command owner width')
    s = _replace(s, 'logic [64+7:0] avmmwr_cmd_q;',
                 'logic [74:0] avmmwr_cmd_q;', 'command queue owner width')
    s = _replace(s, '''assign avmmwr_cmd = {1'b0,{(6-DMA_BRST_CNT_W){1'b0}},
 avmmwr_burstcnt_reg[DMA_BRST_CNT_W-1:0], {(64-RDDMA_AVL_ADDR_WIDTH){1'b0}},
 avmm_address_reg2[RDDMA_AVL_ADDR_WIDTH-1:0]};''', '''
assign avmmwr_cmd = {v2_cmd_slot_pipe, 1'b0, {(6-DMA_BRST_CNT_W){1'b0}},
 avmmwr_burstcnt_reg[DMA_BRST_CNT_W-1:0], {(64-RDDMA_AVL_ADDR_WIDTH){1'b0}},
 avmm_address_reg2[RDDMA_AVL_ADDR_WIDTH-1:0]};''', 'command owner payload')
    s = _replace(s, '.FIFO_DEPTH(16), .DATA_WIDTH(1+6+64)',
                 '.FIFO_DEPTH(16), .DATA_WIDTH(4+1+6+64)', 'command fifo width')
    # Start only when the complete burst is buffered. No speculative read of
    # the next command's data: last accepted beat returns to idle, then pipe.
    s = cut(s, 'always_comb\nbegin\ncase(avmmwr_state)', 'assign RdDmaWrite_o', '''
assign v2_cmd_start = avmmwr_idle_state && avmmwr_cmd_count != 0 &&
  avmmwr_burst_count != 0 && avmmwr_fifo_usedw >= avmmwr_burst_count;
always_comb begin
  case (avmmwr_state)
    AVMMWR_IDLE: avmmwr_nxt_state = v2_cmd_start ? AVMMWR_PIPE : AVMMWR_IDLE;
    AVMMWR_PIPE: avmmwr_nxt_state = AVMMWR_WR;
    AVMMWR_WR: avmmwr_nxt_state = end_avmm_cycle ? AVMMWR_IDLE : AVMMWR_WR;
    default: avmmwr_nxt_state = AVMMWR_IDLE;
  endcase
end
assign avmmwr_idle_state = avmmwr_state == AVMMWR_IDLE;
assign avmmwr_wrpipe_state = avmmwr_state == AVMMWR_PIPE;
assign avmmwr_write_state = avmmwr_state == AVMMWR_WR;
assign avmmwr_data_fifo_rdreq = avmmwr_wrpipe_state ||
  (avmmwr_write_state && !RdDmaWaitRequest_i && avmmwr_burst_cntr > 1);
assign end_avmm_cycle = avmmwr_write_state && !RdDmaWaitRequest_i && avmmwr_burst_cntr == 1;
assign avmmwr_cmd_fifo_rdreq = v2_cmd_start;
''', 'whole burst writer')
    s = cut(s, '''altpcie_fifo
#(
.FIFO_DEPTH(16),
.DATA_WIDTH(32)
)
rd_status_fifo''', 'always_ff @ (posedge Clk_i)\nbegin\ncpl_header_reg',
            '`include "engine_v2_logic.svh"\n', 'replace status FIFO')
    if 'assign rd_status_fifo_rdreq' in s or 'rd_status_fifo\n(' in s:
        raise ValueError('old status transport survived')
    return s

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--source-packet', required=True, type=Path)
    ap.add_argument('--read-engine', required=True, type=Path)
    ap.add_argument('--fifo', required=True, type=Path)
    ap.add_argument('--controller', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    a = ap.parse_args()
    raw = a.source_packet.read_bytes()
    if sha(raw) != PACKET_SHA256:
        raise SystemExit('REFUSED: source packet SHA-256 differs from the supplied request')
    packet = raw.decode('utf-8')
    rendered = section(packet, 'FULL READ ENGINE\n',
        'CONTROLLER qualification/read-dma-retirement-v1/source/altpcie_dynamic_control.sv ORIGINAL LINES 1-80\n')
    fifo_packet = section(packet,
        'FILE qualification/read-dma-retirement-v1/source/altpcie_fifo.sv\n',
        'FILE tests/vcs/read_dma_retirement_tb.sv\n')
    engine = a.read_engine.read_text(); fifo = a.fifo.read_text()
    controller = a.controller.read_text()
    for name, original, supplied in [('read engine', engine, rendered), ('FIFO', fifo, fifo_packet)]:
        if token_values(original) != token_values(supplied):
            raise SystemExit(f'REFUSED: entire {name} token stream differs from source packet')
    audit = controller_audit(controller)
    generated = {
        'altpcieav_dma_rd_candidate_v2.sv': transform_engine(engine),
        'altpcie_dynamic_control_candidate_v2.sv': transform_controller(controller),
        'altpcie_fifo.sv': fifo,
    }
    out = a.out.resolve()
    inputs = [a.source_packet, a.read_engine, a.fifo, a.controller]
    if out.exists() or any(p.resolve().is_relative_to(out) for p in inputs):
        raise SystemExit('REFUSED: --out must be a new isolated directory')
    out.mkdir(parents=True)
    for name, data in generated.items(): (out / name).write_text(data)
    (out / 'source_manifest.json').write_text(json.dumps({
        'request_id': 'acc7af21-c803-482b-9091-de72f0546592',
        'source_packet_sha256': sha(raw), 'production_contract_valid': False,
        'read_engine_sha256': sha(a.read_engine.read_bytes()),
        'fifo_sha256': sha(a.fifo.read_bytes()), 'controller': audit,
        'outputs': {k: sha(v.encode()) for k, v in generated.items()},
        'vcs_executed_by_builder': False,
    }, indent=2) + '\n')
    print(f'Generated isolated candidate: {out}')

if __name__ == '__main__':
    main()
