// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
// Positive transport integration: the actual generated controller is connected
// to the v3 owner. Owner events are unit stimulus, not a full read-engine run.
// The supplied source omits the MSI-pending register decode, so this test does
// not invent its address. Stalled MSI is covered by dma_reuse_v3_tb instead.
module dma_controller_receipt_v3_tb;
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
wire contract_fault, status_valid, status_ready;
wire [31:0] status_word;
wire ack_valid, ack_consumed;
wire [31:0] ack_word;
logic cs = 0, cswrite = 0;
logic [7:0] csaddr = 0;
logic [31:0] csdata = 0;
logic host_stall = 1, fetch_ready = 0;
wire cswait, host_write, diagnostic_valid, controller_fault;
wire fetch_valid;
wire [31:0] fetch_word;
wire [63:0] host_address;
wire [31:0] host_data, diagnostic_data, controller_fault_word;
wire [3:0] host_be;
int cycles = 0, statuses = 0, host_writes = 0;
int fetch_handoffs = 0, legacy_samples = 0, receipts = 0, closures = 0;
int last_fetch_edge = -1, last_legacy_edge = -1;
bit previous_ack = 0, held_write = 0;
logic [31:0] held_ack_word = 0, held_host_data = 0;
logic [63:0] held_host_address = 0;

dma_owner_v3 owner (.*);
altpcie_dynamic_control_candidate_v3 controller (
  .Clk_i(clk), .Rstn_i(rstn), .MsiInterface_i(82'b0),
  .DCSChipSelect_i(cs), .DCSWrite_i(cswrite), .DCSAddress_i(csaddr),
  .DCSWriteData_i(csdata), .DCSByteEnable_i(4'hf), .DCSRead_i(1'b0),
  .DCSReadData_o(), .DCSWaitRequest_o(cswait),
  .DCMAddress_o(host_address), .DCMWrite_o(host_write), .DCMWriteData_o(host_data),
  .DCMRead_o(), .DCMByteEnable_o(host_be), .DCMWaitRequest_i(host_stall),
  .DCMReadData_i(32'b0), .DCMReadDataValid_i(1'b0),
  .DTSChipSelect_i(1'b0), .DTSWrite_i(1'b0), .DTSBurstCount_i(5'b0),
  .DTSAddress_i(8'b0), .DTSWriteData_i(256'b0), .DTSWaitRequest_o(),
  .DmaTxData_o(), .DmaTxValid_o(), .DmaTxReady_i(1'b1),
  .DmaRxData_i(status_word), .DmaRxValid_i(status_valid), .DmaRxReady_o(status_ready),
  .DmaAckValid_o(ack_valid), .DmaAckData_o(ack_word), .DmaAckConsumed_i(ack_consumed),
  .FetchStatusReady_i(fetch_ready),
  .FetchStatusValid_o(fetch_valid), .FetchStatusData_o(fetch_word),
  .StatusDiagnosticValid_o(diagnostic_valid), .StatusDiagnosticReady_i(1'b0),
  .StatusDiagnosticData_o(diagnostic_data), .StatusProtocolFault_o(controller_fault),
  .StatusProtocolFaultWord_o(controller_fault_word),
  .WrDescTxData_o(), .WrDescTxReq_o(), .WrDescTxAck_i(1'b0),
  .WrDescTxAck_o(), .WrDescTxReq_i(1'b0), .WrDescTxData_i(160'b0)
);

function automatic logic [7:0] identity(input int index);
  case (index)
    0: return 8'd7;
    1: return 8'd128;
    2: return 8'd192;
    default: return 8'd0;
  endcase
endfunction
function automatic logic [31:0] success(input int index);
  return status_v2_make(identity(index), 0, 8'(index + 1), 0, 1, 1, 0, 1);
endfunction

always @(posedge clk) begin
  cycles++;
  if (rstn) begin
    if (contract_fault || controller_fault)
      $fatal(1, "positive controller receipt fault owner=%b controller=%b word=%h",
             contract_fault, controller_fault, controller_fault_word);
    if (diagnostic_valid) $fatal(1, "success was routed to diagnostic channel");
    if (status_valid && status_ready) begin
      if (statuses >= 3 || status_word !== success(statuses))
        $fatal(1, "owner/controller status identity mismatch index=%0d word=%h", statuses, status_word);
      statuses++;
    end
    if (held_write && ({host_write,host_address,host_data,host_be} !==
                       {1'b1,held_host_address,held_host_data,4'hf}))
      $fatal(1, "controller flag changed during waitrequest");
    held_write = host_write && host_stall;
    if (held_write) begin held_host_address = host_address; held_host_data = host_data; end
    if (host_write && !host_stall) begin
      if (host_writes != 0 || host_address !== 64'h801c || host_data !== 32'h1 ||
          host_be !== 4'hf || statuses != 1)
        $fatal(1, "wrong/duplicate controller flag or fetch alias addr=%h data=%h", host_address, host_data);
      host_writes++;
    end
    if (fetch_valid && fetch_ready) begin
      if (fetch_handoffs >= 2 || fetch_word !== success(fetch_handoffs + 1))
        $fatal(1, "wrong fetch handoff identity");
      fetch_handoffs++;
      last_fetch_edge = cycles;
    end
    // This is the actual retained ingress register consumed by the unchanged
    // legacy logic at this edge. Its full raw receipt is retained separately.
    if (controller.dma_status_valid_reg) begin
      if (legacy_samples >= 2 || fetch_handoffs != legacy_samples + 1 ||
          controller.dma_status_reg !== {23'b0,1'b1,identity(legacy_samples + 1)} ||
          cycles != last_fetch_edge + 1)
        $fatal(1, "legacy fetch register lost identity or its retained edge");
      legacy_samples++;
      last_legacy_edge = cycles;
    end
    if (ack_valid && !previous_ack) begin
      if (receipts >= 3 || ack_word !== success(receipts) || statuses != receipts + 1)
        $fatal(1, "incorrect controller receipt identity/order: %h", ack_word);
      if (!ack_word[7] && host_writes != 1)
        $fatal(1, "data receipt preceded accepted flag");
      if (ack_word[7] && (legacy_samples != receipts ||
          cycles <= last_legacy_edge || cycles < last_fetch_edge + 2))
        $fatal(1, "fetch receipt preceded the legacy retained-consumer edge");
      held_ack_word = ack_word;
      receipts++;
    end
    if (previous_ack && ack_valid && ack_word !== held_ack_word)
      $fatal(1, "controller changed held receipt identity");
    previous_ack = ack_valid;
    if (ack_consumed && ack_valid && !owner.live_q[0])
      $fatal(1, "controller receipt freed slot before valid-low");
    if (ack_consumed && !ack_valid) begin
      if (closures + 1 != receipts || !owner.live_q[0])
        $fatal(1, "duplicate or premature controller receipt closure");
      closures++;
    end
  end
end

task automatic tick;
  @(posedge clk); @(negedge clk); #1;
endtask
task automatic write_control(input logic [7:0] address, input logic [31:0] value);
  @(negedge clk); csaddr = address; csdata = value; cs = 1; cswrite = 1;
  #1;
  while (cswait) begin @(negedge clk); #1; end
  tick(); cs = 0; cswrite = 0;
endtask
task automatic complete_owner(input logic [7:0] id);
  descriptor_id = id; descriptor_valid = 1;
  #1;
  if (!descriptor_ready || descriptor_slot != 0)
    $fatal(1, "controller closure did not permit slot0 reuse");
  tick(); descriptor_valid = 0;
  start_valid = 1; start_slot = 0;
  tick(); start_valid = 0;
  issue_valid = 1; issue_slot = 0;
  tick(); issue_valid = 0;
  command_valid = 1; command_slot = 0;
  return_valid = 1; return_slot = 0;
  close_valid = 1; close_slot = 0;
  tick(); command_valid = 0; return_valid = 0; close_valid = 0;
  retire_valid = 1; retire_slot = 0;
  tick(); retire_valid = 0;
endtask
task automatic drain_receipt(input int count);
  wait (closures == count);
  tick(); tick();
  if (ack_valid || ack_consumed || owner.live_q != 0 || owner.order_count != 0)
    $fatal(1, "actual controller receipt channel did not close");
endtask

initial begin
  repeat (5) @(negedge clk);
  rstn = 1;
  write_control(8'h00, 32'h8000);
  write_control(8'h18, 32'h1);
  complete_owner(7);
  wait (host_write);
  repeat (7) begin
    tick();
    if (ack_valid || ack_consumed || !owner.live_q[0] || host_writes)
      $fatal(1, "stalled controller flag authorized receipt or reuse");
  end
  host_stall = 0;
  drain_receipt(1);
  for (int index = 1; index <= 2; index++) begin
    complete_owner(identity(index));
    wait (fetch_valid);
    repeat (9) begin
      tick();
      if (!fetch_valid || fetch_word !== success(index) ||
          ack_valid || ack_consumed || controller.dma_status_valid_reg ||
          host_write || !owner.live_q[0])
        $fatal(1, "stalled fetch status escaped, aliased data or authorized reuse");
    end
    fetch_ready = 1;
    tick(); fetch_ready = 0;
    drain_receipt(index + 1);
  end
  if (statuses != 3 || host_writes != 1 || fetch_handoffs != 2 ||
      legacy_samples != 2 || receipts != 3 || closures != 3)
    $fatal(1, "positive actual-controller receipt accounting mismatch");
  $display("PASS actual controller-v3 data7/fetch128/fetch192, retained fetch edge, stalled transport, fourphase closure, no reset");
  $finish;
end
endmodule
