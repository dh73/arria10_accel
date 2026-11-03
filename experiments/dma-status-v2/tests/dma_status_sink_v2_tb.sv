// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
module dma_status_sink_v2_tb;
import dma_status_v2_pkg::*;
logic clk = 0, rstn = 0;
always #5 clk = ~clk;
logic valid = 0, msi = 0, waitrequest = 0, fetch_ready = 0, diagnostic_ready = 0;
logic [31:0] word = 0;
logic [63:0] base = 64'h8000;
logic [81:0] msi_interface = 0;
wire ready, write_req, fetch_valid, diagnostic_valid, ack_valid, fault;
wire [63:0] write_address;
wire [31:0] write_data, fetch_word, diagnostic_word, ack_word, fault_word;
wire [3:0] byteenable;
logic [63:0] expected_address [32];
logic [31:0] expected_data [32], expected_ack [32];
int wanted_writes = 0, writes = 0, wanted_acks = 0, acks = 0;
int cycles = 0, accepts = 0, fetches = 0, diagnostics = 0;
logic [31:0] expected_fetch = 0, expected_diagnostic = 0;
bit allow_fault = 0, held_write = 0, held_fetch = 0, held_diagnostic = 0;
logic [63:0] held_address;
logic [31:0] held_data, held_fetch_word, held_diagnostic_word;
dma_status_sink_v2 #(.DEPTH(4)) dut (
.clk(clk), .rstn(rstn), .s_valid(valid), .s_ready(ready), .s_word(word),
.s_msi(msi), .header_base(base), .msi_interface(msi_interface),
.dcm_write(write_req), .dcm_address(write_address), .dcm_data(write_data),
.dcm_byteenable(byteenable), .dcm_waitrequest(waitrequest),
.fetch_valid(fetch_valid), .fetch_ready(fetch_ready), .fetch_word(fetch_word),
.diagnostic_valid(diagnostic_valid), .diagnostic_ready(diagnostic_ready),
.diagnostic_word(diagnostic_word), .retired_ack_valid(ack_valid),
.retired_ack_word(ack_word), .protocol_fault(fault), .fault_word(fault_word)
);
function automatic logic [31:0] success(input int id, input int slot, input int generation);
return status_v2_make(8'(id), 4'(slot), 8'(generation), 0, 1, 1, 0, 1);
endfunction
function automatic logic [31:0] failure(input int id, input int slot);
return status_v2_make(8'(id), 4'(slot), 8'd1, DMA_CAUSE_MASTER, 0, 1, 1, 0);
endfunction
always @(posedge clk) begin
cycles++;
if (cycles > 10000) $fatal(1, "sink watchdog");
if (!rstn) begin
held_write = 0; held_fetch = 0; held_diagnostic = 0;
end else begin
if (fault && !allow_fault) $fatal(1, "unexpected sink fault %h", fault_word);
if (valid && ready) accepts++;
if (held_write && ({write_req, write_address, write_data, byteenable} !== {1'b1, held_address, held_data, 4'hf}))
$fatal(1, "posted flag/MSI changed while waitrequest asserted");
held_write = write_req && waitrequest;
if (held_write) begin held_address = write_address; held_data = write_data; end
if (write_req && !waitrequest) begin
if (writes >= wanted_writes || write_address !== expected_address[writes] || write_data !== expected_data[writes] || byteenable !== 4'hf)
$fatal(1, "wrong posted write index=%0d addr=%h data=%h", writes, write_address, write_data);
writes++;
end
if (held_fetch && ({fetch_valid, fetch_word} !== {1'b1, held_fetch_word})) $fatal(1, "fetch status lost under backpressure");
held_fetch = fetch_valid && !fetch_ready;
if (held_fetch) held_fetch_word = fetch_word;
if (fetch_valid && fetch_ready) begin
if (fetch_word !== expected_fetch) $fatal(1, "wrong fetch identity %h", fetch_word);
fetches++;
end
if (held_diagnostic && ({diagnostic_valid, diagnostic_word} !== {1'b1, held_diagnostic_word})) $fatal(1, "fetch error lost under backpressure");
held_diagnostic = diagnostic_valid && !diagnostic_ready;
if (held_diagnostic) held_diagnostic_word = diagnostic_word;
if (diagnostic_valid && diagnostic_ready) begin
if (diagnostic_word !== expected_diagnostic) $fatal(1, "wrong diagnostic %h", diagnostic_word);
diagnostics++;
end
if (ack_valid) begin
if (acks >= wanted_acks || ack_word !== expected_ack[acks] || !status_v2_success(ack_word))
$fatal(1, "incorrect retirement acknowledgement %h", ack_word);
acks++;
end
end
end
task automatic expect_write(input logic [63:0] address, input logic [31:0] data);
expected_address[wanted_writes] = address;
expected_data[wanted_writes] = data;
wanted_writes++;
endtask
task automatic expect_ack(input logic [31:0] value);
expected_ack[wanted_acks] = value;
wanted_acks++;
endtask
task automatic send(input logic [31:0] value, input bit request_msi = 0);
@(negedge clk); valid = 1; word = value; msi = request_msi;
while (!ready) @(negedge clk);
@(posedge clk); @(negedge clk); valid = 0; msi = 0;
endtask
task automatic reset_local;
@(negedge clk); rstn = 0; valid = 0; msi = 0;
waitrequest = 0; fetch_ready = 0; diagnostic_ready = 0;
repeat (3) @(negedge clk);
wanted_writes = 0; writes = 0; wanted_acks = 0; acks = 0;
accepts = 0; fetches = 0; diagnostics = 0; allow_fault = 0;
base = 64'h8000; msi_interface = 0; rstn = 1;
endtask
task automatic drain;
wait (writes == wanted_writes && acks == wanted_acks);
repeat (8) @(negedge clk);
if (write_req || fetch_valid || diagnostic_valid || ack_valid || fault)
$fatal(1, "sink did not drain");
endtask
task automatic reject(input logic [31:0] value);
reset_local();
allow_fault = 1;
send(value);
wait (fault);
repeat (6) @(negedge clk);
if (fault_word !== value || ready || write_req || fetch_valid || diagnostic_valid || ack_valid || writes || acks)
$fatal(1, "malformed word was not retained and blocked: %h", value);
endtask
initial begin : run
logic [31:0] w, p, s;
reset_local();
w = failure(7, 0);
p = status_v2_make(8'd7, 4'd0, 8'd1, DMA_CAUSE_PAUSE, 0, 0, 0, 0);
s = success(7, 0, 1);
expect_write(64'h801c, w);
expect_write(64'h801c, p);
expect_write(64'h801c, 32'h1);
expect_ack(s);
send(w); send(p); send(s);
drain();
if (acks != 1) $fatal(1, "error/pause authorized retirement");
reset_local();
s = success(9, 2, 3);
waitrequest = 1;
msi_interface[80] = 1;
msi_interface[79:64] = 16'hbeef;
msi_interface[63:0] = 64'ha000;
expect_write(64'h8024, 32'h1);
expect_write(64'ha000, 32'hbeef);
expect_ack(s);
send(s, 1);
wait (write_req);
@(negedge clk); base = 64'h9000; msi_interface = 0;
repeat (7) @(negedge clk);
if (acks != 0) $fatal(1, "ack before stalled flag write");
waitrequest = 0;
@(posedge clk); @(negedge clk); waitrequest = 1;
if (writes != 1 || acks != 0 || write_address != 64'ha000)
$fatal(1, "MSI snapshot/order/retirement failure");
repeat (7) @(negedge clk);
if (acks != 0) $fatal(1, "ack before MSI acceptance");
waitrequest = 0;
drain();
reset_local();
waitrequest = 1;
for (int i = 0; i < 5; i++) expect_write(64'h8000 + 4 * i, failure(i, i));
for (int i = 0; i < 4; i++) send(failure(i, i));
repeat (4) @(negedge clk);
if (ready || accepts != 4) $fatal(1, "full sink did not backpressure");
fork
send(failure(4, 4));
begin
repeat (12) @(negedge clk);
if (accepts != 4 || writes != 0) $fatal(1, "full sink accepted/dropped a fifth entry");
waitrequest = 0;
end
join
drain();
if (accepts != 5 || writes != 5 || acks != 0) $fatal(1, "finite error queue lost entry");
reset_local();
expected_fetch = success(128, 0, 1);
expected_diagnostic = failure(192, 1);
expect_ack(expected_fetch);
send(expected_fetch);
send(expected_diagnostic);
wait (fetch_valid);
repeat (12) @(negedge clk);
if (writes || acks || diagnostic_valid) $fatal(1, "fetch backpressure bypassed");
fetch_ready = 1;
wait (fetches == 1);
@(negedge clk); fetch_ready = 0;
wait (diagnostic_valid);
repeat (12) @(negedge clk);
if (writes || diagnostics || acks != 1) $fatal(1, "fetch error aliased host data or was lost");
diagnostic_ready = 1;
wait (diagnostics == 1);
@(negedge clk); diagnostic_ready = 0;
drain();
reject(32'h00000000);
reject(status_v2_make(8'd7, 4'd0, 8'd0, 0, 1, 1, 0, 1));
reject(status_v2_make(8'd7, 4'd0, 8'd1, DMA_CAUSE_MASTER, 1, 1, 1, 1));
$display("PASS candidate-v2 status sink identity/errors/fetch/full/reset/MSI/malformed");
$finish;
end
endmodule
