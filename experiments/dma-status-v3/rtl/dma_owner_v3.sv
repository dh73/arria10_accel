// SPDX-License-Identifier: BSD-3-Clause
// Four-phase success receipt. ack_consumed stays high until the connected
// producer withdraws ack_valid; only that low observation permits slot reuse.
// Wire status version remains 2; generation is a bounded diagnostic, not a
// replay authenticator. See README.md for transport/reset assumptions.
module dma_owner_v3 (
input logic clk, rstn,
input logic descriptor_valid,
output logic descriptor_ready,
input logic descriptor_room,
input logic [7:0] descriptor_id,
output logic [3:0] descriptor_slot,
input logic start_valid,
input logic [3:0] start_slot,
input logic current_valid,
input logic [3:0] current_slot,
input logic issue_valid,
input logic [3:0] issue_slot,
input logic return_valid,
input logic [3:0] return_slot,
input logic command_valid,
input logic [3:0] command_slot,
input logic retire_valid,
input logic [3:0] retire_slot,
input logic close_valid,
input logic [3:0] close_slot,
input logic master_error,
input logic control_valid,
input logic [3:0] control_data,
output logic control_ready,
output logic [15:0] halted,
input logic external_fault,
output logic contract_fault,
output logic status_valid,
input logic status_ready,
output logic [31:0] status_word,
input logic ack_valid,
input logic [31:0] ack_word,
output logic ack_consumed
);
import dma_status_v2_pkg::*;
logic [15:0] live_q, live_d, started_q, started_d, closed_q, closed_d;
logic [15:0] pause_q, pause_d, staged_q, staged_d, delivered_q, delivered_d;
logic [7:0] id_q[16], id_d[16], generation_q[16], generation_d[16];
logic [7:0] reads_q[16], reads_d[16], commands_q[16], commands_d[16];
logic [3:0] cause_q[16], cause_d[16], reported_q[16], reported_d[16];
logic fault_q, fault_d, out_valid_q, out_valid_d;
logic [31:0] out_word_q, out_word_d;
logic [3:0] cursor_q, cursor_d;
logic [3:0] admission_order[16];
logic [3:0] order_read, order_write;
logic [4:0] order_count;
logic ack_release;
logic receipt_q, receipt_d;
logic [31:0] receipt_word_q, receipt_word_d;
logic found_free, duplicate_id, event_waiting, accepted_control, selected;
integer n, pick, delta;
always_comb begin
found_free = 1'b0;
duplicate_id = 1'b0;
descriptor_slot = 4'h0;
event_waiting = |pause_q;
halted = '0;
for (int i = 0; i < 16; i++) begin
if (!found_free && !live_q[i]) begin
found_free = 1'b1;
descriptor_slot = 4'(i);
end
duplicate_id |= live_q[i] && id_q[i] == descriptor_id;
event_waiting |= cause_q[i] != reported_q[i];
halted[i] = live_q[i] && (cause_q[i] & 4'hd) != 0;
end
control_ready = rstn && !fault_q && !external_fault &&
!out_valid_q && !event_waiting;
accepted_control = control_valid && control_ready;
descriptor_ready = rstn && descriptor_room && found_free && order_count < 16 &&
!duplicate_id && !fault_q && !external_fault &&
!(accepted_control && control_data[3]);
end
assign status_valid = rstn && out_valid_q;
assign status_word = out_word_q;
assign contract_fault = fault_q;
assign ack_consumed = rstn && receipt_q;
always_comb begin
live_d = live_q; started_d = started_q; closed_d = closed_q;
pause_d = pause_q; staged_d = staged_q; delivered_d = delivered_q;
fault_d = fault_q | external_fault;
out_valid_d = out_valid_q; out_word_d = out_word_q; cursor_d = cursor_q;
selected = 1'b0;
ack_release = 1'b0;
receipt_d = receipt_q;
receipt_word_d = receipt_word_q;
n = 0; pick = 0; delta = 0;
for (int i = 0; i < 16; i++) begin
id_d[i] = id_q[i]; generation_d[i] = generation_q[i];
reads_d[i] = reads_q[i]; commands_d[i] = commands_q[i];
cause_d[i] = cause_q[i]; reported_d[i] = reported_q[i];
end
if (out_valid_q && status_ready) begin
out_valid_d = 1'b0;
if (status_v2_success(out_word_q))
delivered_d[out_word_q[15:12]] = 1'b1;
end
if (descriptor_valid && descriptor_ready) begin
n = int'(descriptor_slot);
live_d[n] = 1'b1; started_d[n] = 1'b0; closed_d[n] = 1'b0;
pause_d[n] = 1'b0; staged_d[n] = 1'b0; delivered_d[n] = 1'b0;
id_d[n] = descriptor_id;
generation_d[n] = generation_q[n] == 8'hff ? 8'h1 : generation_q[n] + 8'h1;
reads_d[n] = '0; commands_d[n] = '0;
cause_d[n] = '0; reported_d[n] = '0;
end
if (start_valid) begin
if (!live_q[start_slot] || started_q[start_slot] || halted[start_slot])
fault_d = 1'b1;
else started_d[start_slot] = 1'b1;
end
if (close_valid) begin
if (!live_q[close_slot] || !started_q[close_slot]) fault_d = 1'b1;
else closed_d[close_slot] = 1'b1;
end
for (int i = 0; i < 16; i++) begin
if ((issue_valid && issue_slot == i) || (return_valid && return_slot == i)) begin
delta = int'(issue_valid && issue_slot == i) - int'(return_valid && return_slot == i);
if (!live_q[i] || staged_q[i] ||
(return_valid && return_slot == i && reads_q[i] == 0) ||
(issue_valid && issue_slot == i && (closed_q[i] || !started_q[i])) ||
int'(reads_q[i]) + delta < 0 || int'(reads_q[i]) + delta > 16)
fault_d = 1'b1;
else reads_d[i] = 8'(int'(reads_q[i]) + delta);
end
if ((command_valid && command_slot == i) || (retire_valid && retire_slot == i)) begin
delta = int'(command_valid && command_slot == i) - int'(retire_valid && retire_slot == i);
if (!live_q[i] || staged_q[i] ||
(command_valid && command_slot == i && reads_q[i] == 0) ||
(retire_valid && retire_slot == i && commands_q[i] == 0) ||
int'(commands_q[i]) + delta < 0 || int'(commands_q[i]) + delta > 16)
fault_d = 1'b1;
else commands_d[i] = 8'(int'(commands_q[i]) + delta);
end
end
if (accepted_control) begin
if (control_data[3]) begin
for (int i = 0; i < 16; i++) begin
if (live_q[i] && !staged_q[i]) begin
cause_d[i] |= DMA_CAUSE_FLUSH;
if (pause_q[i]) cause_d[i] |= DMA_CAUSE_PAUSE;
pause_d[i] = 1'b0;
if (!started_q[i]) closed_d[i] = 1'b1;
end
end
end
if (current_valid && live_q[current_slot] && !staged_q[current_slot]) begin
if (control_data[2]) cause_d[current_slot] |= DMA_CAUSE_ABORT;
if (control_data[0] && !control_data[1]) begin
if ((cause_d[current_slot] & 4'hd) != 0)
cause_d[current_slot] |= DMA_CAUSE_PAUSE;
else pause_d[current_slot] = 1'b1;
end
if ((cause_d[current_slot] & 4'hd) != 0 && pause_q[current_slot]) begin
cause_d[current_slot] |= DMA_CAUSE_PAUSE;
pause_d[current_slot] = 1'b0;
end
end
end
if (master_error && current_valid && live_q[current_slot] && !staged_q[current_slot]) begin
cause_d[current_slot] |= DMA_CAUSE_MASTER;
if (pause_d[current_slot]) cause_d[current_slot] |= DMA_CAUSE_PAUSE;
pause_d[current_slot] = 1'b0;
end
// Process receipts AFTER accounting/error events. A fault on the withdrawal
// edge must not free anything. A stable held high is one request, not replay.
if (receipt_q) begin
  n = int'(receipt_word_q[15:12]);
  if (ack_valid) begin
    if (ack_word != receipt_word_q) fault_d = 1'b1;
  end else if (!fault_d) begin
    if (order_count != 0 && admission_order[order_read] == n &&
        live_q[n] && staged_q[n] && delivered_q[n] && closed_q[n] &&
        reads_d[n] == 0 && commands_d[n] == 0 && cause_d[n] == 0 &&
        receipt_word_q == status_v2_make(id_q[n], 4'(n), generation_q[n],
          4'h0, 1'b1, 1'b1, 1'b0, 1'b1)) begin
      live_d[n] = 1'b0;
      started_d[n] = 1'b0;
      staged_d[n] = 1'b0;
      delivered_d[n] = 1'b0;
      receipt_d = 1'b0;
      receipt_word_d = '0;
      ack_release = 1'b1;
    end else fault_d = 1'b1;
  end
end else if (ack_valid) begin
  n = int'(ack_word[15:12]);
  if (!fault_d && status_v2_success(ack_word) && order_count != 0 &&
      admission_order[order_read] == n && live_q[n] && staged_q[n] &&
      delivered_d[n] && closed_q[n] && reads_d[n] == 0 &&
      commands_d[n] == 0 && cause_d[n] == 0 &&
      ack_word == status_v2_make(id_q[n], 4'(n), generation_q[n],
        4'h0, 1'b1, 1'b1, 1'b0, 1'b1)) begin
    receipt_d = 1'b1;
    receipt_word_d = ack_word;
  end else fault_d = 1'b1;
end
if (!out_valid_d && !accepted_control && !fault_d) begin
for (int j = 0; j < 16; j++) begin
pick = (int'(cursor_q) + j) % 16;
if (!selected && live_d[pick]) begin
if (cause_d[pick] != reported_d[pick]) begin
out_word_d = status_v2_make(id_d[pick], 4'(pick), generation_d[pick],
cause_d[pick], 1'b0, 1'b1, 1'b1, 1'b0);
reported_d[pick] = cause_d[pick];
pause_d[pick] = 1'b0;
selected = 1'b1;
end else if (pause_d[pick]) begin
out_word_d = status_v2_make(id_d[pick], 4'(pick), generation_d[pick],
DMA_CAUSE_PAUSE, 1'b0, 1'b0, 1'b0, 1'b0);
pause_d[pick] = 1'b0;
selected = 1'b1;
end else if (order_count != 0 && admission_order[order_read] == pick &&
!staged_d[pick] && closed_d[pick] &&
reads_d[pick] == 0 && commands_d[pick] == 0 &&
cause_d[pick] == 0) begin
out_word_d = status_v2_make(id_d[pick], 4'(pick), generation_d[pick],
4'h0, 1'b1, 1'b1, 1'b0, 1'b1);
staged_d[pick] = 1'b1;
selected = 1'b1;
end
if (selected) cursor_d = 4'((pick + 1) % 16);
end
end
if (selected) out_valid_d = 1'b1;
end
end
always_ff @(posedge clk or negedge rstn) begin
if (!rstn) begin
live_q <= '0; started_q <= '0; closed_q <= '0;
pause_q <= '0; staged_q <= '0; delivered_q <= '0;
fault_q <= 1'b0; out_valid_q <= 1'b0; out_word_q <= '0; cursor_q <= '0;
order_read <= '0; order_write <= '0; order_count <= '0;
receipt_q <= 1'b0; receipt_word_q <= '0;
for (int i = 0; i < 16; i++) begin
id_q[i] <= '0; generation_q[i] <= '0; reads_q[i] <= '0;
commands_q[i] <= '0; cause_q[i] <= '0; reported_q[i] <= '0;
end
end else begin
case ({descriptor_valid && descriptor_ready, ack_release})
2'b10: order_count <= order_count + 1'b1;
2'b01: order_count <= order_count - 1'b1;
default: ;
endcase
if (descriptor_valid && descriptor_ready) begin
admission_order[order_write] <= descriptor_slot;
order_write <= order_write + 1'b1;
end
if (ack_release) order_read <= order_read + 1'b1;
receipt_q <= receipt_d; receipt_word_q <= receipt_word_d;
live_q <= live_d; started_q <= started_d; closed_q <= closed_d;
pause_q <= pause_d; staged_q <= staged_d; delivered_q <= delivered_d;
fault_q <= fault_d; out_valid_q <= out_valid_d;
out_word_q <= out_word_d; cursor_q <= cursor_d;
for (int i = 0; i < 16; i++) begin
id_q[i] <= id_d[i]; generation_q[i] <= generation_d[i];
reads_q[i] <= reads_d[i]; commands_q[i] <= commands_d[i];
cause_q[i] <= cause_d[i]; reported_q[i] <= reported_d[i];
end
end
end
// synthesis translate_off
assert property (@(posedge clk) disable iff (!rstn)
status_valid && !status_ready |=> status_valid && $stable(status_word));
assert property (@(posedge clk) disable iff (!rstn)
status_valid |-> status_v2_valid(status_word));
assert property (@(posedge clk) disable iff (!rstn) order_count <= 16);
// Local structural guarantees: source custody, single delivery, and a low
// receipt phase before release. These are assertions, not environment cuts.
assert property (@(posedge clk) disable iff (!rstn)
  ack_release |-> receipt_q && !ack_valid && !fault_d);
assert property (@(posedge clk) disable iff (!rstn)
  receipt_q |-> live_q[receipt_word_q[15:12]] &&
                 staged_q[receipt_word_q[15:12]] &&
                 delivered_q[receipt_word_q[15:12]]);
assert property (@(posedge clk) disable iff (!rstn)
  receipt_q && ack_valid |=> receipt_q && $stable(receipt_word_q));
assert property (@(posedge clk) disable iff (!rstn)
  status_valid && status_ready && status_v2_success(status_word) |->
    live_q[status_word[15:12]] && staged_q[status_word[15:12]] &&
    !delivered_q[status_word[15:12]]);
for (genvar k = 0; k < 16; k++) begin: reuse_assertions
  assert property (@(posedge clk) disable iff (!rstn)
    $fell(live_q[k]) |-> $past(ack_release && receipt_word_q[15:12] == k));
  assert property (@(posedge clk) disable iff (!rstn)
    descriptor_valid && descriptor_ready && descriptor_slot == k |-> !live_q[k]);
end
// synthesis translate_on
endmodule
