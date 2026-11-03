// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
module read_dma_candidate_v2_tb;
localparam int MAX_DESC = 32;
localparam int MAX_REQ = 2 * MAX_DESC;
localparam int MAX_PKT_BEATS = 5 * MAX_REQ;
logic clk = 0, rstn = 0;
always #5 clk = ~clk;
logic desc_valid = 0, stall = 1, status_ready = 1;
logic master_enable = 1, grant_enable = 1;
logic ctrl_load = 0;
logic [31:0] ctrl_data = 0;
logic [159:0] desc = 0;
logic ack_valid = 0;
logic [31:0] ack_data = 0;
wire ready, wr, rx_pop, tx_push, arb, tag_pop, status_valid;
wire ctrl_ready, contract_fault;
wire [63:0] addr;
wire [255:0] data;
wire [31:0] be, status_data, control_status;
wire [4:0] burst;
wire [259:0] tx;
logic [265:0] packets [MAX_PKT_BEATS];
logic [7:0] request_tag [MAX_REQ];
int request_owner [MAX_REQ], request_segment [MAX_REQ];
logic [7:0] ids [MAX_DESC];
bit issued [MAX_DESC], terminal_seen [MAX_DESC], expected_error [MAX_DESC];
int expected_cause [MAX_DESC];
int request_by_owner [MAX_DESC], beats_by_owner [MAX_DESC];
int terminal_by_owner [MAX_DESC], pause_by_owner [MAX_DESC];
logic [7:0] seen_beats [MAX_DESC];
logic [31:0] completed_word [MAX_DESC];
int offered = 0, consumed = 0, requests = 0, accepted = 0;
int statuses = 0, terminal_statuses = 0, pauses = 0, in_burst = 0;
int target_count = 0, accepted_desc = 0, cycles = 0;
int scenario = 0, ndesc = 1, mode = 0;
bit held_status = 0, saw_input_backpressure = 0;
logic [31:0] held_status_data;
bit held_write = 0;
logic [63:0] held_addr;
logic [255:0] held_data;
logic [31:0] held_be;
logic [4:0] held_burst;
wire [265:0] rx = consumed < offered ? packets[consumed] : 266'b0;
wire [3:0] rx_count = consumed < offered ? 4'd1 : 4'd0;
altpcieav_dma_rd_candidate_v2 #(
.DMA_WIDTH(256), .DMA_BE_WIDTH(32), .RDDMA_AVL_ADDR_WIDTH(64),
.DEVICE_FAMILY("Arria 10")
) dut (
.Clk_i(clk), .Rstn_i(rstn), .RdDmaWrite_o(wr), .RdDmaAddress_o(addr),
.RdDmaWriteData_o(data), .RdDmaBurstCount_o(burst), .RdDmaWriteEnable_o(be),
.RdDmaWaitRequest_i(stall), .RdDmaRxData_i(desc), .RdDmaRxValid_i(desc_valid),
.RdDmaRxReady_o(ready), .RdDmaTxData_o(status_data), .RdDmaTxValid_o(status_valid),
.RdDmaTxReady_i(status_ready), .RdDmaAckValid_i(ack_valid),
.RdDmaAckData_i(ack_data), .RdDMACntrlReady_o(ctrl_ready),
.ContractFault_o(contract_fault),
.RxFifoRdReq_o(rx_pop), .RxFifoDataq_i(rx), .RxFifoCount_i(rx_count),
.PreDecodeTagRdReq_o(tag_pop), .PreDecodeTag_i(rx[79:72]),
.PreDecodeTagCount_i(rx_count), .TxFifoWrReq_o(tx_push),
.TxFifoData_o(tx), .TxFifoCount_i(4'b0),
.RdDMACntrlLoad_i(ctrl_load), .RdDMACntrlData_i(ctrl_data),
.RdDMAStatus_o(control_status), .RdDMmaArbReq_o(arb),
.RdDMmaArbGranted_i(arb && grant_enable), .BusDev_i(13'h100),
.DevCsr_i(32'b0), .MasterEnable_i(master_enable),
.ko_cpl_spc_header(8'hff), .ko_cpl_spc_data(12'hfff)
);
function automatic logic [63:0] source_address(input int d);
return 64'h1000 + 64'h1000 * d;
endfunction
function automatic logic [63:0] destination_address(input int d);
return 64'h100000 + 64'h1000 * d;
endfunction
function automatic logic [31:0] payload(input int d, input int w);
return 32'hcafe0000 + 32'h1000 * d + w;
endfunction
always @(posedge clk) begin : monitor
int d, segment, owner, offset;
logic [63:0] effective_address;
cycles++;
if (cycles > 200000) $fatal(1, "watchdog scenario=%0d requests=%0d beats=%0d statuses=%0d", scenario, requests, accepted, statuses);
if (!rstn) begin
ack_valid <= 0;
ack_data <= 0;
held_status = 0;
held_write = 0;
end else begin
if (contract_fault !== 1'b0) $fatal(1, "candidate contract fault or X");
ack_valid <= 0;
if (desc_valid && !ready) saw_input_backpressure = 1;
if (desc_valid && ready) accepted_desc++;
if (rx_pop) begin
if (consumed >= offered) $fatal(1, "RX FIFO underflow");
consumed <= consumed + 1;
end
if (tx_push) begin
if ($isunknown(tx) || tx[9:0] !== 10'd32 || tx[31:24] !== 8'h00)
$fatal(1, "unexpected memory read header %h", tx);
d = (int'(tx[95:64]) - 'h1000) / 'h1000;
if (d < 0 || d >= target_count || !issued[d]) $fatal(1, "MRd has no accepted owner source=%h", tx[95:64]);
segment = (int'(tx[95:64]) - int'(source_address(d))) / 128;
if (segment < 0 || segment > 1 || tx[95:64] !== 32'(source_address(d) + 128 * segment))
$fatal(1, "wrong MRd source %h", tx[95:64]);
if (requests >= MAX_REQ || request_by_owner[d] >= 2) $fatal(1, "too many MRds");
request_tag[requests] = tx[47:40];
request_owner[requests] = d;
request_segment[requests] = segment;
request_by_owner[d]++;
requests++;
end
if (held_write && ({wr, addr, data, be, burst} !== {1'b1, held_addr, held_data, held_be, held_burst}))
$fatal(1, "Avalon request changed while waitrequest was asserted");
held_write = wr && stall;
if (held_write) begin
held_addr = addr; held_data = data; held_be = be; held_burst = burst;
end
if (wr && !stall) begin
if ($isunknown({addr, burst, be, data}) || burst !== 5'd4 || be !== 32'hffffffff)
$fatal(1, "invalid Avalon beat address=%h burst=%0d be=%h", addr, burst, be);
effective_address = addr + 32 * in_burst;
d = (int'(effective_address) - 'h100000) / 'h1000;
if (d < 0 || d >= target_count || !issued[d]) $fatal(1, "payload has no owner address=%h", effective_address);
offset = int'(effective_address - destination_address(d));
if (offset < 0 || offset >= 256 || (offset % 32) != 0)
$fatal(1, "payload address out of bounds owner=%0d address=%h", d, effective_address);
if (seen_beats[d][offset / 32]) $fatal(1, "duplicate payload beat owner=%0d offset=%0d", d, offset);
seen_beats[d][offset / 32] = 1;
for (int lane = 0; lane < 8; lane++)
if (data[32*lane +: 32] !== payload(d, offset / 4 + lane))
$fatal(1, "wrong payload owner=%0d offset=%0d lane=%0d actual=%h", d, offset, lane, data[32*lane +: 32]);
beats_by_owner[d]++;
accepted++;
in_burst = (in_burst + 1) % 4;
end
if (held_status && ({status_valid, status_data} !== {1'b1, held_status_data}))
$fatal(1, "status changed while backpressured");
held_status = status_valid && !status_ready;
if (held_status) held_status_data = status_data;
if (status_valid && status_ready) begin
statuses++;
if ($isunknown(status_data) || status_data[31:28] !== 4'h2 || status_data[23:16] == 0)
$fatal(1, "bad candidate-v2 status %h", status_data);
owner = -1;
for (int j = 0; j < target_count; j++)
if (issued[j] && !terminal_seen[j] && ids[j] == status_data[7:0] && owner == -1) owner = j;
if (owner < 0) $fatal(1, "status lost identity or duplicated terminal word=%h", status_data);
if (status_data[8]) begin
if (status_data[27:24] != 0 || status_data[11:8] !== 4'hd || expected_error[owner])
$fatal(1, "invalid success encoding %h", status_data);
if (beats_by_owner[owner] != 8 || seen_beats[owner] !== 8'hff || request_by_owner[owner] != 2)
$fatal(1, "premature success id=%0d accepted_beats=%0d requests=%0d", ids[owner], beats_by_owner[owner], request_by_owner[owner]);
for (int j = 0; j < owner; j++)
if (!terminal_seen[j] || expected_error[j])
$fatal(1, "success bypassed an earlier unretired/quarantined descriptor");
for (int j = 0; j < owner; j++)
if (terminal_seen[j] && ids[j] == ids[owner] && completed_word[j] == status_data)
$fatal(1, "reused ID repeated the old slot/generation identity");
completed_word[owner] = status_data;
terminal_seen[owner] = 1;
terminal_by_owner[owner]++;
terminal_statuses++;
ack_valid <= 1;
ack_data <= status_data;
end else if (status_data[9]) begin
if (!expected_error[owner] || status_data[27:24] != expected_cause[owner] || !status_data[10] || status_data[11])
$fatal(1, "wrong error identity/cause/retirement %h owner=%0d", status_data, owner);
terminal_seen[owner] = 1;
terminal_by_owner[owner]++;
terminal_statuses++;
end else begin
if (status_data[27:24] !== 4'h2 || status_data[11:8] !== 4'h0)
$fatal(1, "wrong nonterminal status %h", status_data);
pause_by_owner[owner]++;
pauses++;
end
$display("STATUS raw=%h id=%0d owner=%0d accepted_beats=%0d", status_data, ids[owner], owner, beats_by_owner[owner]);
end
end
end
task automatic initialize(input int count);
target_count = count;
for (int i = 0; i < MAX_DESC; i++) begin
ids[i] = 8'(7 + i); issued[i] = 0; terminal_seen[i] = 0;
expected_error[i] = 0; expected_cause[i] = 0;
request_by_owner[i] = 0; beats_by_owner[i] = 0;
terminal_by_owner[i] = 0; pause_by_owner[i] = 0; seen_beats[i] = 0;
completed_word[i] = 0;
end
repeat (5) @(negedge clk);
rstn = 1;
repeat (80) @(negedge clk);
endtask
task automatic submit(input int d);
@(negedge clk);
desc = 0;
desc[63:0] = source_address(d);
desc[127:64] = destination_address(d);
desc[145:128] = 18'd64;
desc[153:146] = ids[d];
desc_valid = 1;
#1;
while (!ready) begin @(negedge clk); #1; end
issued[d] = 1;
@(posedge clk);
@(negedge clk);
desc_valid = 0;
endtask
task automatic command(input logic [31:0] value);
@(negedge clk);
ctrl_load = 1; ctrl_data = value;
#1;
while (!ctrl_ready) begin @(negedge clk); #1; end
@(posedge clk);
@(negedge clk);
ctrl_load = 0; ctrl_data = 0;
endtask
task automatic append_completion(input int r);
int base, d, seg, pos;
@(negedge clk);
base = offered;
d = request_owner[r]; seg = request_segment[r];
if (base + 5 > MAX_PKT_BEATS) $fatal(1, "TB packet storage exhausted");
for (int p = 0; p < 5; p++) packets[base+p] = 0;
packets[base][31:0] = 32'h4a000020;
packets[base][63:32] = 32'h00000080;
packets[base][95:64] = {16'h0800, request_tag[r], 8'h00};
packets[base][256] = 1;
for (int w = 0; w < 32; w++) begin
pos = w + 4;
packets[base+pos/8][(pos%8)*32 +: 32] = payload(d, 32 * seg + w);
end
packets[base+4][257] = 1;
packets[base+4][259:258] = 2'b10;
offered += 5;
endtask
task automatic feed_all(input int first, input int count, input bit reverse, input bit gaps);
for (int j = 0; j < count; j++) begin
append_completion(reverse ? first + count - 1 - j : first + j);
if (gaps) begin
wait (consumed == offered);
repeat (11 + (j % 3)) @(negedge clk);
end
end
endtask
task automatic finish_check(input int terminals);
wait (terminal_statuses == terminals);
repeat (12) @(negedge clk);
if (terminal_statuses != terminals || ack_valid || held_status || in_burst != 0)
$fatal(1, "unexpected status/backlog after test drain");
$display("PASS candidate-v2 scenario=%0d n=%0d mode=%0d requests=%0d accepted=%0d terminals=%0d pauses=%0d", scenario, target_count, mode, requests, accepted, terminal_statuses, pauses);
$finish;
endtask
initial begin : stimulus
if (!$value$plusargs("SCENARIO=%d", scenario)) scenario = 0;
if (!$value$plusargs("N=%d", ndesc)) ndesc = 1;
if (!$value$plusargs("MODE=%d", mode)) mode = 0;
if (ndesc < 1 || ndesc > 16) $fatal(1, "N must be in 1..16");
case (scenario)
0: begin : successful_payloads
initialize(ndesc);
stall = mode == 1 || mode == 3 || mode == 5;
status_ready = mode != 4 && mode != 5;
for (int j = 0; j < ndesc; j++) submit(j);
wait (requests == 2 * ndesc);
feed_all(0, requests, mode == 3 || mode == 5, mode == 2);
if (stall) begin
repeat (200) @(negedge clk);
stall = 0;
end
wait (accepted == 8 * ndesc);
if (!status_ready) begin
repeat (23) @(negedge clk);
if (statuses != 0) $fatal(1, "status consumed despite ready=0");
status_ready = 1;
end
finish_check(ndesc);
end
1: begin : disabled_master
initialize(ndesc);
master_enable = 0;
stall = 0;
status_ready = 0;
for (int j = 0; j < ndesc; j++) begin
expected_error[j] = 1; expected_cause[j] = 1;
submit(j);
end
repeat (80) @(negedge clk);
if (requests || accepted || statuses) $fatal(1, "disabled master issued payload or status was consumed without ready");
status_ready = 1;
wait (terminal_statuses == ndesc);
if (requests || accepted) $fatal(1, "master-disabled descriptor issued payload");
if (ndesc == 16) begin
@(negedge clk);
desc[153:146] = 8'd63; desc_valid = 1;
repeat (16) begin
@(negedge clk);
if (ready) $fatal(1, "error output freed a finite owner slot");
end
desc_valid = 0;
if (accepted_desc != 16 || !saw_input_backpressure)
$fatal(1, "finite owner backpressure was not exercised");
end
finish_check(ndesc);
end
2: begin : reused_identity
initialize(2);
ids[1] = ids[0];
stall = 0;
submit(0);
wait (requests == 2);
feed_all(0, 2, 1, 0);
wait (terminal_statuses == 1);
submit(1);
wait (requests == 4);
feed_all(2, 2, 0, 1);
finish_check(2);
end
3: begin : fetch_ids
initialize(2);
ids[0] = 8'd128; ids[1] = 8'd192;
stall = 0;
submit(0); submit(1);
wait (requests == 4);
feed_all(0, 4, 1, 0);
finish_check(2);
end
4: begin : last_beat_and_master_error
initialize(2);
expected_error[1] = 1; expected_cause[1] = 1;
submit(0);
wait (requests == 2);
@(negedge clk); grant_enable = 0;
submit(1);
repeat (12) @(negedge clk);
feed_all(0, 2, 0, 0);
wait (consumed == offered);
repeat (12) @(negedge clk);
stall = 0;
wait (accepted == 7);
@(negedge clk); master_enable = 0;
finish_check(2);
end
5: begin : pause_and_resume
initialize(1);
grant_enable = 0;
submit(0);
repeat (12) @(negedge clk);
command(32'h1);
wait (pauses == 1);
if (requests || terminal_statuses) $fatal(1, "pause was terminal or emitted a read");
command(32'h2);
grant_enable = 1; stall = 0;
wait (requests == 2);
feed_all(0, 2, 0, 0);
finish_check(1);
end
6: begin : abort_keeps_future_payload
initialize(1);
expected_error[0] = 1; expected_cause[0] = 4;
submit(0);
wait (requests == 1);
@(negedge clk); grant_enable = 0;
command(32'h4);
wait (terminal_statuses == 1);
if (requests != 1) $fatal(1, "abort test did not stop after one MRd");
append_completion(0);
stall = 0;
wait (accepted == 4);
finish_check(1);
end
7: begin : flush_preserves_queued_ids
initialize(3);
grant_enable = 0; stall = 0;
for (int j = 0; j < 3; j++) begin
expected_error[j] = 1; expected_cause[j] = 8;
submit(j);
end
command(32'h8);
wait (terminal_statuses == 3);
if (requests || accepted) $fatal(1, "queued flush issued payload");
finish_check(3);
end
default: $fatal(1, "unknown SCENARIO");
endcase
end
endmodule
