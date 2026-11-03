// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
module dma_owner_v2_tb;
import dma_status_v2_pkg::*;
logic clk = 0, rstn = 0;
always #5 clk = ~clk;
logic descriptor_valid = 0, descriptor_room = 1;
logic [7:0] descriptor_id = 0;
wire descriptor_ready;
wire [3:0] descriptor_slot;
logic start_valid = 0, current_valid = 0, issue_valid = 0, return_valid = 0;
logic command_valid = 0, retire_valid = 0, close_valid = 0, master_error = 0;
logic [3:0] start_slot = 0, current_slot = 0, issue_slot = 0, return_slot = 0;
logic [3:0] command_slot = 0, retire_slot = 0, close_slot = 0;
logic control_valid = 0;
logic [3:0] control_data = 0;
wire control_ready;
wire [15:0] halted;
logic external_fault = 0;
wire contract_fault, status_valid;
logic status_ready = 0;
wire [31:0] status_word;
logic ack_valid = 0;
logic [31:0] ack_word = 0;
int cycles = 0;
dma_owner_v2 dut (.*);
always @(posedge clk) begin
cycles++;
if (cycles > 100000) $fatal(1, "owner watchdog");
end
task automatic tick;
@(posedge clk); @(negedge clk);
endtask
task automatic clear_inputs;
descriptor_valid = 0; start_valid = 0; current_valid = 0;
issue_valid = 0; return_valid = 0; command_valid = 0; retire_valid = 0;
close_valid = 0; master_error = 0; control_valid = 0;
control_data = 0; external_fault = 0; ack_valid = 0; status_ready = 0;
endtask
task automatic reset_local;
@(negedge clk); rstn = 0; clear_inputs();
repeat (3) @(negedge clk);
rstn = 1;
tick();
if (contract_fault || status_valid) $fatal(1, "reset did not clear local owner state");
endtask
task automatic allocate(input logic [7:0] id, output logic [3:0] slot);
descriptor_id = id; descriptor_valid = 1;
#1;
if (!descriptor_ready) $fatal(1, "owner allocation unexpectedly blocked id=%0d", id);
slot = descriptor_slot;
tick(); descriptor_valid = 0;
start_slot = slot; start_valid = 1;
tick(); start_valid = 0;
endtask
task automatic consume(output logic [31:0] value);
while (!status_valid) @(negedge clk);
value = status_word;
status_ready = 1;
tick(); status_ready = 0;
endtask
task automatic acknowledge(input logic [31:0] value);
ack_word = value; ack_valid = 1;
tick(); ack_valid = 0;
endtask
initial begin
logic [3:0] a, b;
logic [31:0] first, second, good, previous;
reset_local();
allocate(8'd7, a);
issue_valid = 1; issue_slot = a;
tick(); issue_valid = 0;
command_valid = 1; command_slot = a;
tick(); command_valid = 0;
close_valid = 1; close_slot = a; return_valid = 1; return_slot = a;
tick(); close_valid = 0; return_valid = 0;
repeat (6) tick();
if (status_valid) $fatal(1, "CplD/tag return retired an unaccepted payload command");
allocate(8'd8, b);
retire_valid = 1; retire_slot = a;
master_error = 1; current_valid = 1; current_slot = b;
tick(); retire_valid = 0; master_error = 0; current_valid = 0;
while (!status_valid) @(negedge clk);
previous = status_word;
repeat (6) begin
tick();
if (!status_valid || status_word !== previous) $fatal(1, "backpressured owner status changed");
end
consume(first);
consume(second);
if (status_v2_success(first) && first[7:0] == 7) good = first;
else if (status_v2_success(second) && second[7:0] == 7) good = second;
else $fatal(1, "simultaneous events lost successful identity");
if (!((first[7:0] == 8 && first[27:24] == 1 && first[11:8] == 6) ||
(second[7:0] == 8 && second[27:24] == 1 && second[11:8] == 6)))
$fatal(1, "simultaneous events lost failed identity");
acknowledge(good);
if (contract_fault) $fatal(1, "valid success acknowledgement faulted");
descriptor_id = 8;
#1;
if (descriptor_ready) $fatal(1, "error consumption freed identity8");
allocate(8'd7, a);
acknowledge(good);
if (!contract_fault || descriptor_ready) $fatal(1, "stale previous generation acknowledgement was accepted");
reset_local();
return_valid = 1; return_slot = 0;
tick(); return_valid = 0;
if (!contract_fault) $fatal(1, "unowned completion counter decrement was accepted");
reset_local();
for (int slot = 0; slot < 16; slot++) begin
for (int generation = 1; generation <= 255; generation++) begin
allocate(8'd7, a);
if (a != slot) $fatal(1, "unexpected generation allocation order");
close_valid = 1; close_slot = a;
tick(); close_valid = 0;
consume(good);
if (!status_v2_success(good) || good[15:12] != slot || good[23:16] != generation || good[7:0] != 7)
$fatal(1, "generation wrapped or identity lost %h", good);
acknowledge(good);
if (contract_fault) $fatal(1, "valid generation lifecycle faulted");
end
end
descriptor_id = 7;
#1;
if (descriptor_ready || status_valid) $fatal(1, "all exhausted slots did not stop admission");
$display("PASS owner-v2 exact simultaneous retirement/error, stale ack, local reset, generation exhaustion");
$finish;
end
endmodule
