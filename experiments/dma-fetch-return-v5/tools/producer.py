# SPDX-License-Identifier: BSD-3-Clause
"""Source-pinned native producer transformations and ownership metadata."""
from __future__ import annotations
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
V4_PATH = ROOT.parent / "dma-fetch-v4" / "tools" / "build.py"
spec = importlib.util.spec_from_file_location("fetch_return_v4_source", V4_PATH)
V4 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V4)
tokens, once, sha = V4.tokens, V4.once, V4.sha

ENGINE_SHA = "3cbb20d52dd12b18ddfd38e2b057b43424e9badb00e9b11229a023d452eec6f9"
OWNER_SHA = "3fb008cf34da0c8d20367b66ae2db6bc8e1a1590f0a75137474927375cbbc712"
INCLUDE_SHA = "e97c806a57a5fde5624b1889212bac389bb146870e43a1b160d938135b08ac8a"
DECLARATIONS_SHA = "03ae104e42c9d491495db4e922927accf3efa1bb57c01965a8cd2900604ade63"

ENGINE_PORTS = """
input logic FetchEnable_i,
input logic [31:0] FetchEpoch_i,
output logic [31:0] ReturnEpoch_o,
output logic [19:0] ReturnToken_o,
output logic [63:0] ReturnBase_o,
output logic [7:0] ReturnCount_o,
output logic FetchEndValid_o,
input logic FetchEndReady_i,
output logic [31:0] FetchEndEpoch_o,
output logic [19:0] FetchEndToken_o,
output logic FetchEndError_o,
input logic ReturnRouteFault_i,
output logic ReturnFault_o,
output logic [31:0] ReturnFaultEpoch_o,
output logic [19:0] ReturnFaultToken_o,
output logic [7:0] ReturnFaultReason_o, ReturnFaultTag_o,
"""


def engine(raw: bytes) -> str:
    if sha(raw) != ENGINE_SHA:
        raise ValueError("v4 engine SHA256 mismatch (original bytes required)")
    s = raw.decode("utf-8")
    s = tokens(s, "module altpcieav_dma_rd_fetch_v4 # (",
               "module altpcieav_dma_rd_fetch_return_v5 # (")
    s = tokens(s, "output logic FetchBindValid_o,",
               ENGINE_PORTS + "output logic FetchBindValid_o,")
    s = once(s, '`include "engine_v2_declarations.svh"',
             '`include "engine_v2_declarations.svh"\n'
             '`include "engine_return_declarations_v5.svh"')
    s = once(s, '`include "engine_fetch_v4.svh"',
             '`include "engine_fetch_return_v5.svh"')
    for name in ("desc_head", "desc_fifo_wrdat"):
        s = tokens(s, f"logic [RDDMA_RXDATA_WIDTH+3:0] {name};",
                   f"logic [RDDMA_RXDATA_WIDTH+3+V5_META_W:0] {name};")
    s = tokens(s, ".FIFO_DEPTH(6), .DATA_WIDTH(RDDMA_RXDATA_WIDTH+4)",
               ".FIFO_DEPTH(6), .DATA_WIDTH(RDDMA_RXDATA_WIDTH+4+V5_META_W)")
    s = tokens(s, "assign desc_fifo_wrdat = {v2_alloc_slot, RdDmaRxData_i};",
               "assign desc_fifo_wrdat = {v5_admit_meta, v2_alloc_slot, RdDmaRxData_i};")
    for name in ("avmmwr_cmd", "avmmwr_cmd_q"):
        s = tokens(s, f"logic [74:0] {name};", f"logic [74+V5_META_W:0] {name};")
    s = tokens(s, "assign avmmwr_cmd = {v2_cmd_slot_pipe,",
               "assign avmmwr_cmd = {v5_cmd_meta_pipe, v2_cmd_slot_pipe,")
    s = tokens(s, ".FIFO_DEPTH(16), .DATA_WIDTH(4+1+6+64)",
               ".FIFO_DEPTH(16), .DATA_WIDTH(V5_META_W+4+1+6+64)")
    return s


def declarations() -> str:
    raw = (ROOT.parent / "dma-status-v2/rtl/engine_v2_declarations.svh").read_bytes()
    if sha(raw) != DECLARATIONS_SHA:
        raise ValueError("original engine declarations SHA256 mismatch")
    return raw.decode()


def engine_include() -> str:
    s = V4.engine_include()
    if sha(s.encode()) != INCLUDE_SHA:
        raise ValueError("regenerated v4 engine include SHA256 mismatch")
    s = tokens(s, "dma_owner_fetch_v4 v2_owners (",
               "dma_owner_fetch_return_v5 v2_owners (")
    s = tokens(s, ".descriptor_token(FetchBindToken_o),", """
.descriptor_token(FetchBindToken_o),
.descriptor_enable(FetchEnable_i), .descriptor_epoch(FetchEpoch_i),
.session_fault(v5_session_fault),
.fetch_end_valid(FetchEndValid_o), .fetch_end_ready(FetchEndReady_i),
.fetch_end_epoch(FetchEndEpoch_o), .fetch_end_token(FetchEndToken_o),
.fetch_end_error(FetchEndError_o),""")
    s = tokens(s, "rx_dwlen == 0 || rx_dwlen > remain_dw);",
               "rx_dwlen == 0 || rx_dwlen > remain_dw || v5_bad_completion_shape);")
    s = tokens(s, "assign v2_external_fault = v2_guard_fault || v2_bad_header;", """
assign v2_external_fault = v2_guard_fault || v2_bad_header ||
  v5_guard_fault || v5_session_fault || ReturnRouteFault_i || v5_fault_q;""")
    s = tokens(s, "RXFIFO_DATA_WIDTH != 266 || TX_FIFO_WIDTH != 260)",
               "RXFIFO_DATA_WIDTH != 266 || TX_FIFO_WIDTH != 260 || RDDMA_AVL_ADDR_WIDTH != 64)")
    s += '\n`include "engine_return_v5.svh"\n'
    return s


OWNER_DECL = """
// End is an independent per-owner settlement channel, not a status pulse.
logic [15:0] v5_end_done_q, v5_end_done_d;
logic [31:0] v5_epoch_q[16], v5_epoch_d[16];
logic v5_end_valid_q, v5_end_valid_d, v5_end_error_q, v5_end_error_d;
logic [31:0] v5_end_epoch_q, v5_end_epoch_d;
logic [19:0] v5_end_token_q, v5_end_token_d;
logic [3:0] v5_end_cursor_q, v5_end_cursor_d;
logic v5_end_selected;
integer v5_end_pick;
logic v5_session_valid_q;
logic [31:0] v5_session_epoch_q;
assign session_fault = v5_session_valid_q &&
  (descriptor_epoch != v5_session_epoch_q || (!descriptor_enable && (|live_q)));
assign fetch_end_valid = rstn && v5_end_valid_q;
assign fetch_end_epoch = v5_end_epoch_q;
assign fetch_end_token = v5_end_token_q;
assign fetch_end_error = v5_end_error_q;
"""

OWNER_DEFAULT = """
v5_end_done_d = v5_end_done_q;
v5_end_valid_d = v5_end_valid_q;
v5_end_epoch_d = v5_end_epoch_q; v5_end_token_d = v5_end_token_q;
v5_end_error_d = v5_end_error_q; v5_end_cursor_d = v5_end_cursor_q;
v5_end_selected = 1'b0; v5_end_pick = 0;
for (int v5_i=0;v5_i<16;v5_i++) v5_epoch_d[v5_i] = v5_epoch_q[v5_i];
if (v5_end_valid_q && fetch_end_ready) begin
  v5_end_valid_d = 1'b0;
  v5_end_done_d[v5_end_token_q[11:8]] = 1'b1;
end
"""

OWNER_END_SELECT = """
// All next-state debts include this edge's issue, return, command and actual
// destination acceptance. Registering the offer makes it occur AFTER that
// last acceptance. No global FIFO-empty condition or elapsed-cycle rule.
if (!v5_end_valid_d && !fault_d) begin
  for (int v5_j=0;v5_j<16;v5_j++) begin
    v5_end_pick = (int'(v5_end_cursor_q)+v5_j)%16;
    if (!v5_end_selected && live_d[v5_end_pick] && id_d[v5_end_pick][7] &&
        closed_d[v5_end_pick] && reads_d[v5_end_pick]==0 &&
        commands_d[v5_end_pick]==0 && !v5_end_done_d[v5_end_pick]) begin
      v5_end_selected = 1'b1; v5_end_valid_d = 1'b1;
      v5_end_token_d = {generation_d[v5_end_pick],4'(v5_end_pick),id_d[v5_end_pick]};
      v5_end_epoch_d = v5_epoch_d[v5_end_pick];
      v5_end_error_d = (cause_d[v5_end_pick] & 4'hd) != 0;
      v5_end_cursor_d = 4'((v5_end_pick+1)%16);
    end
  end
end
"""

OWNER_ASSERTIONS = """
// synthesis translate_off
assert property (@(posedge clk) disable iff(!rstn)
  fetch_end_valid && !fetch_end_ready |=> fetch_end_valid &&
  $stable({fetch_end_epoch,fetch_end_token,fetch_end_error}));
assert property (@(posedge clk) disable iff(!rstn)
  fetch_end_valid |-> live_q[fetch_end_token[11:8]] &&
  closed_q[fetch_end_token[11:8]] && reads_q[fetch_end_token[11:8]]==0 &&
  commands_q[fetch_end_token[11:8]]==0 && !v5_end_done_q[fetch_end_token[11:8]] &&
  fetch_end_token=={generation_q[fetch_end_token[11:8]],fetch_end_token[11:8],
                   id_q[fetch_end_token[11:8]]} &&
  fetch_end_epoch==v5_epoch_q[fetch_end_token[11:8]]);
assert property (@(posedge clk) disable iff(!rstn)
  status_valid && status_v2_success(status_word) && status_word[7] |->
  v5_end_done_q[status_word[15:12]]);
assert property (@(posedge clk) disable iff(!rstn)
  descriptor_valid && descriptor_ready |->
  descriptor_enable && v5_session_valid_q && !session_fault &&
  !live_q[descriptor_slot] && descriptor_token[19:12]!=0);
for (genvar v5_k=0;v5_k<16;v5_k++) begin: return_fence_assertions
  assert property (@(posedge clk) disable iff(!rstn)
    live_q[v5_k] && $past(live_q[v5_k]) |->
    $stable({v5_epoch_q[v5_k],id_q[v5_k],generation_q[v5_k]}));
  assert property (@(posedge clk) disable iff(!rstn)
    $rose(v5_end_done_q[v5_k]) |->
    $past(fetch_end_valid && fetch_end_ready && fetch_end_token[11:8]==v5_k));
  assert property (@(posedge clk) disable iff(!rstn)
    $past(rstn) && $changed(generation_q[v5_k]) |->
    $past(descriptor_valid && descriptor_ready && descriptor_slot==v5_k && !live_q[v5_k]));
  assert property (@(posedge clk) disable iff(!rstn)
    descriptor_valid && descriptor_ready && descriptor_slot==v5_k |=>
    generation_q[v5_k]==($past(generation_q[v5_k])==8'hff ?
                         8'h01 : $past(generation_q[v5_k])+8'h01));
  assert property (@(posedge clk) disable iff(!rstn)
    descriptor_valid && descriptor_ready && descriptor_slot==v5_k &&
    generation_q[v5_k]==8'hff |=> generation_q[v5_k]==8'h01);
end
// synthesis translate_on
"""


def owner() -> str:
    s = V4.owner()
    if sha(s.encode()) != OWNER_SHA:
        raise ValueError("regenerated v4 owner SHA256 mismatch")
    s = tokens(s, "module dma_owner_fetch_v4 (", "module dma_owner_fetch_return_v5 (")
    s = tokens(s, "output logic [19:0] descriptor_token,", """
output logic [19:0] descriptor_token,
input logic descriptor_enable,
input logic [31:0] descriptor_epoch,
output logic session_fault,
output logic fetch_end_valid,
input logic fetch_end_ready,
output logic [31:0] fetch_end_epoch,
output logic [19:0] fetch_end_token,
output logic fetch_end_error,""")
    s = tokens(s, "integer n, pick, delta;", "integer n, pick, delta;\n" + OWNER_DECL)
    # Preserve the source allocator and ff->1 generation recurrence. Reuse is
    # fenced by settled owner debts, accepted End, the exact receipt protocol,
    # and controller/consumer bank credit, not an added lifetime admission cap.
    s = tokens(s, "control_ready = rstn && !fault_q && !external_fault &&",
               "control_ready = rstn && !fault_q && !external_fault && !session_fault &&")
    s = tokens(s, "descriptor_ready = rstn && descriptor_room && found_free && order_count < 16 &&",
               "descriptor_ready = rstn && descriptor_enable && v5_session_valid_q && !session_fault &&\n"
               "descriptor_room && found_free && order_count < 16 &&")
    s = tokens(s, "generation_d[n] = generation_q[n] == 8'hff ? 8'h1 : generation_q[n] + 8'h1;",
               "generation_d[n] = generation_q[n] == 8'hff ? 8'h1 : generation_q[n] + 8'h1;\n"
               "v5_epoch_d[n] = descriptor_epoch; v5_end_done_d[n] = 1'b0;")
    s = tokens(s, "fault_d = fault_q | external_fault;",
               "fault_d = fault_q | external_fault | session_fault;\n" + OWNER_DEFAULT)
    # Success issuance and ACK retirement both require delivered close for fetch.
    s = tokens(s, "!staged_d[pick] && closed_d[pick] &&",
               "!staged_d[pick] && closed_d[pick] &&\n"
               "(!id_d[pick][7] || v5_end_done_d[pick]) &&")
    s = tokens(s, "reads_d[n] == 0 && commands_d[n] == 0 && cause_d[n] == 0 &&",
               "reads_d[n] == 0 && commands_d[n] == 0 && cause_d[n] == 0 &&\n"
               "(!id_q[n][7] || v5_end_done_d[n]) &&", count=2)
    s = tokens(s, "if (selected) out_valid_d = 1'b1;\n  end\nend",
               "if (selected) out_valid_d = 1'b1;\n  end\n" + OWNER_END_SELECT + "\nend")
    s = tokens(s, "receipt_q <= 1'b0; receipt_word_q <= '0;", """
receipt_q <= 1'b0; receipt_word_q <= '0;
v5_end_done_q <= '0; v5_end_valid_q <= 1'b0;
v5_end_epoch_q <= '0; v5_end_token_q <= '0; v5_end_error_q <= 1'b0;
v5_end_cursor_q <= '0; v5_session_valid_q <= 1'b0; v5_session_epoch_q <= '0;
for (int v5_i=0;v5_i<16;v5_i++) v5_epoch_q[v5_i] <= '0;""")
    s = tokens(s, "receipt_q <= receipt_d; receipt_word_q <= receipt_word_d;", """
receipt_q <= receipt_d; receipt_word_q <= receipt_word_d;
v5_end_done_q <= v5_end_done_d; v5_end_valid_q <= v5_end_valid_d;
v5_end_epoch_q <= v5_end_epoch_d; v5_end_token_q <= v5_end_token_d;
v5_end_error_q <= v5_end_error_d; v5_end_cursor_q <= v5_end_cursor_d;
for (int v5_i=0;v5_i<16;v5_i++) v5_epoch_q[v5_i] <= v5_epoch_d[v5_i];
if (descriptor_enable && !v5_session_valid_q) begin
  v5_session_valid_q <= 1'b1; v5_session_epoch_q <= descriptor_epoch;
end""")
    return tokens(s, "endmodule", OWNER_ASSERTIONS + "\nendmodule")
