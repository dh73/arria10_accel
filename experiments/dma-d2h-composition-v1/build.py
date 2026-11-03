#!/usr/bin/env python3
"""Exact-byte, isolated derivatives; never write into the source tree.

The licensed controller and wrapper remain private. The frozen owned full-byte
oracle is reused verbatim except its ingress/environment/stimulus boundaries.
"""
from __future__ import annotations
import hashlib

CONTROLLER_SHA = '019de60946a09d16053a8cf15148a5fcbea700b1f4c9c44fd12e0485cbdabd65'
TX_SHA = 'dd0291be6e02508db0243112552451de33bc4d82a08487c60f8bd10a0a851fa1'
BENCH_SHA = '3e03653094556f636567938df606c3b009b071e7b0c14dff8e6110bd995323e6'


def checked(raw: bytes, pin: str) -> str:
    if hashlib.sha256(raw).hexdigest() != pin:
        raise ValueError('exact source identity mismatch; no newline normalization permitted')
    return raw.decode('utf-8')


def once(s: str, old: str, new: str) -> str:
    if s.count(old) != 1:
        raise ValueError('missing/ambiguous transformation anchor: ' + repr(old[:100]))
    return s.replace(old, new, 1)


def span(s: str, first: str, last: str, new: str) -> str:
    if s.count(first) != 1 or s.count(last) != 1:
        raise ValueError('missing/ambiguous source region')
    a, b = s.index(first), s.index(last)
    if b <= a:
        raise ValueError('reversed source region')
    return s[:a] + new + s[b:]


def build_controller(raw: bytes, original: bool = False) -> bytes:
    s = checked(raw, CONTROLLER_SHA)
    s = once(s, 'module altpcie_dynamic_control_write_v4 #(',
             'module altpcie_dynamic_control_write_d2h_v1 #(')
    s = once(s, 'input logic [159:0] WrDescTxData_i );', '''input logic [159:0] WrDescTxData_i,
output wire RetireFault_o,
output wire [31:0] RetireFaultData_o,
output wire [7:0] RetireExpectedId_o,
output wire RetireBusy_o );''')
    if original:
        # Diagnostic-only variant: identical controller behavior, renamed, with
        # inert observation ports. It retains the original reset/status bugs.
        s = once(s, '\nendmodule\n', '''
assign RetireFault_o=1'b0;
assign RetireFaultData_o=32'b0;
assign RetireExpectedId_o=8'b0;
assign RetireBusy_o=(ep_last_fifo_count!=0);
endmodule
''')
        return s.encode('utf-8')
    s = once(s, '`include "controller_tx_v4.svh"', '''logic c1_can_issue, c1_config_busy, c1_doorbell_block, c1_fault;
`include "controller_tx_v4.svh"''')
    s = once(s, "dma_status_valid_reg <= 1'b1;", "dma_status_valid_reg <= 1'b0;")
    s = once(s, "assign v4_tx_fault = 1'b0;", 'assign v4_tx_fault = c1_fault;')
    old = '''assign register_ready_reg = (dcs_current_state[2] | dcs_current_state[3]) &&
        !(DCSWrite_i && desc_controller_slave_address!=8'h10 &&
          desc_controller_slave_address!=8'h18 && v4_config_busy);'''
    new = '''// Configuration cannot retag queued DTS work or retained completions.
// Different doorbells can queue; a live endpoint cannot be assigned twice.
assign register_ready_reg = (dcs_current_state[2] | dcs_current_state[3]) &&
  !(DCSWrite_i && ((desc_controller_slave_address==8'h10) ?
      c1_doorbell_block : c1_config_busy));'''
    s = once(s, old, new)
    s = once(s, 'assign DTSWaitRequest_o = !Rstn_i || !dt_fifo_ok;',
             'assign DTSWaitRequest_o = !Rstn_i || !dt_fifo_ok || c1_fault;')
    s = span(s, '/// Queue to handle EP last update to software', '\nendmodule\n',
             '`include "controller_retirement_v1.svh"\n')
    return s.encode('utf-8')


def build_tx(raw: bytes, original: bool = False) -> bytes:
    s = checked(raw, TX_SHA)
    if original:
        return raw
    # Only this isolated write-controller copy sees these new ownership gates.
    # While held, no competing issuer can consume the offered credit/ID. A
    # retained fault is the existing explicit unaccepted-offer cancellation.
    s = once(s, 'assign DmaTxValid_o = Rstn_i && v4_raw_valid &&',
             'assign DmaTxValid_o = Rstn_i && !c1_fault && c1_can_issue && v4_raw_valid &&')
    s = once(s, 'else if (!dt_fifo_empty) dma_tx_state<=DMA_TX_FIFO_RD;',
             'else if (!dt_fifo_empty && !c1_fault) dma_tx_state<=DMA_TX_FIFO_RD;')
    return s.encode('utf-8')


def build_bench(raw: bytes) -> bytes:
    s = checked(raw, BENCH_SHA)
    s = once(s, 'module native_d2h_packetizer_tb;', 'module d2h_composition_tb;')
    s = once(s, '  logic [159:0] rx_data=0;\n  logic rx_valid=0;',
             '  wire [159:0] rx_data;\n  wire rx_valid;')
    s = once(s, '  logic [259:0] tx_fifo[$],side_fifo[$],side_expected_enqueue[$],side_expected_drain[$];',
             '  logic [259:0] side_fifo[$],side_expected_enqueue[$],side_expected_drain[$];')
    s = once(s, '  // One monitor owns ingress, TX enqueue and status.',
             '  `include "composition_io.svh"\n\n  // One monitor owns ingress, TX enqueue and status.')
    s = once(s, 'if(sink_pop && tx_fifo.size()!=0) begin word=tx_fifo.pop_front();accept_packet_word(word,1);end',
             'if(tx_pop) begin word=tx_front;accept_packet_word(word,1);end')
    s = once(s, 'accept_packet_word(tx_data,0);tx_fifo.push_back(tx_data);',
             'accept_packet_word(tx_data,0);')
    # All remaining occupancy uses observe the real, source-pinned FIFO.
    if s.count('tx_fifo.size()') != 9:
        raise ValueError('unexpected frozen FIFO observer shape')
    s = s.replace('tx_fifo.size()', "int'(tx_used)")
    s = once(s, "if(int'(tx_used)>=32)", "if(int'(tx_used)>=32 && !tx_pop)")
    s = span(s, '  task automatic submit(', '  task automatic drain;', '')
    s = span(s, '  initial begin : run', '\nendmodule\n',
             '  `include "composition_stimulus.svh"\n')
    # Keep both packet decoders and memory/read/credit oracles byte-identical.
    return s.encode('utf-8')
