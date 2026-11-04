// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
`default_nettype none
`ifdef IDENTITY_MMIO
`define IDENTITY_DUT dut.identity
`else
`define IDENTITY_DUT dut
`endif
module tb;
  `include "shell_identity_params.svh"
  logic clk = 0;
  always #5 clk = ~clk;
  logic cold_reset_n = 0;
  logic context_valid = 0, health_valid = 1, ecc_fault = 0;
  logic [127:0] session = 128'h00000004000000030000000200000001;
  logic [63:0] epoch = 64'd9;
  logic req_valid = 0;
  logic [15:0] req_address = 0;
  logic [3:0] req_byteenable = 4'hf;
  wire req_ready, rsp_valid, rsp_error;
  wire [31:0] rsp_data;
  logic cmd_valid = 0, stop_ack = 1;
  wire [2:0] state_status, phase_status;
  wire release_ready, fault_latched, launch_permit, host_submit_permit;
  wire [15:0] fault_history, fault_pending, first_fault_code;
  wire [7:0] first_adapter_code;
  wire [34:0] first_adapter_address;
  wire first_adapter_address_valid, adapter_stopped;

  // TEST ONLY empty producer/adapter certificates; not scheduler/DMA/CDC logic.
  platform_supervisor supervisor (
    .clk(clk), .cold_reset_n(cold_reset_n),
    .memory_ready(1'b1), .backend_init_failed(1'b0),
    .backend_ecc_interrupt(ecc_fault),
    .adapter_fault(1'b0), .adapter_fault_code(8'b0),
    .adapter_fault_address(35'b0), .adapter_fault_address_valid(1'b0),
    .adapter_quiescing(adapter_stopped), .adapter_drained(adapter_stopped),
    .kernel_status_valid(1'b1), .kernel_stop_ack(stop_ack),
    .kernel_idle(1'b1), .kernel_fault(1'b0),
    .host_status_valid(1'b1), .host_stop_ack(stop_ack),
    .host_dma_drained(1'b1), .host_desc_drained(1'b1),
    .host_writeback_drained(1'b1), .host_fault(1'b0),
    .external_stop(1'b0), .cmd_valid(cmd_valid), .cmd_op(3'd0),
    .clear_valid(1'b0), .clear_mask(16'b0),
    .launch_permit(launch_permit), .host_submit_permit(host_submit_permit),
    .kernel_stop_req(), .host_stop_req(),
    .adapter_quiesce_req(adapter_stopped),
    .state_status(state_status), .phase_status(phase_status),
    .release_ready(release_ready), .fault_latched(fault_latched),
    .fault_history(fault_history), .fault_pending(fault_pending),
    .first_fault_code(first_fault_code), .first_adapter_code(first_adapter_code),
    .first_adapter_address(first_adapter_address),
    .first_adapter_address_valid(first_adapter_address_valid),
    .cmd_ready(), .cmd_done(), .cmd_accepted(), .cmd_reason(),
    .clear_done(), .clear_blocked(), .reset_request(), .epoch_advance()
  );
`ifdef IDENTITY_MMIO
  wire mmio_waitrequest;
  assign req_ready = !mmio_waitrequest;
  shell_identity_mmio #(
`else
  shell_identity_v1 #(
`endif
    .SOURCE_ID(ID_SOURCE), .BUILD_ID(ID_BUILD),
    .MGMT_SPACE(ID_MGMT_SPACE), .CRA_SPACE(ID_CRA_SPACE),
    .MGMT_BASE(ID_MGMT_BASE), .CRA_BASE(ID_CRA_BASE), .CRA_BYTES(ID_CRA_BYTES)
  ) dut (
    .clk(clk), .cold_reset_n(cold_reset_n),
    .context_valid(context_valid), .session(session), .epoch(epoch),
    .health_valid(health_valid),
    .state_status(state_status), .phase_status(phase_status),
    .release_ready(release_ready), .fault_latched(fault_latched),
    .launch_permit(launch_permit), .host_submit_permit(host_submit_permit),
    .fault_history(fault_history), .fault_pending(fault_pending),
    .first_fault_code(first_fault_code), .first_adapter_code(first_adapter_code),
    .first_adapter_address(first_adapter_address),
    .first_adapter_address_valid(first_adapter_address_valid),
`ifdef IDENTITY_MMIO
    .read(req_valid), .write(1'b0), .address(ID_MGMT_BASE + {48'b0,req_address}),
    .byteenable(req_byteenable), .waitrequest(mmio_waitrequest),
    .readdatavalid(rsp_valid), .readdata(rsp_data), .invalid_access()
`else
    .req_valid(req_valid), .req_address(req_address),
    .req_byteenable(req_byteenable), .req_ready(req_ready),
    .rsp_valid(rsp_valid), .rsp_error(rsp_error), .rsp_data(rsp_data)
`endif
  );

  // Exercise rejected RTL elaboration parameters, not just host range checks.
  wire [4:0] bad_valid, bad_error;
  wire [31:0] bad_data [0:4];
  for (genvar g=0;g<5;g++) begin : bad_parameters
    localparam logic [63:0] BAD_BASE = g==0 ? 64'h1000 :
      g==1 ? 64'h2004 : g==2 ? 64'hfffffffffffffe00 : 64'h2000;
    shell_identity_v1 #(
      .SOURCE_ID(g==4 ? 256'b0 : ID_SOURCE), .BUILD_ID(ID_BUILD),
      .MGMT_SPACE(32'd7), .CRA_SPACE(32'd7), .MGMT_BASE(64'h1000),
      .CRA_BASE(BAD_BASE), .CRA_BYTES(g==3 ? 64'd0 : 64'd512)
    ) invalid_dut (
      .clk(clk), .cold_reset_n(cold_reset_n),
      .context_valid(context_valid), .session(session), .epoch(epoch),
      .health_valid(1'b0), .state_status(3'b0), .phase_status(3'b0),
      .release_ready(1'b0), .fault_latched(1'b0),
      .launch_permit(1'b0), .host_submit_permit(1'b0),
      .fault_history(16'b0), .fault_pending(16'b0), .first_fault_code(16'b0),
      .first_adapter_code(8'b0), .first_adapter_address(35'b0),
      .first_adapter_address_valid(1'b0),
      .req_valid(req_valid), .req_address(req_address), .req_byteenable(req_byteenable),
      .req_ready(), .rsp_valid(bad_valid[g]), .rsp_error(bad_error[g]),
      .rsp_data(bad_data[g])
    );
  end

  task automatic transfer(input logic [15:0] address,
                          input logic [3:0] be,
                          input bit expected_error,
                          output logic [31:0] value);
    @(negedge clk);
    req_valid = 1; req_address = address; req_byteenable = be;
    if (req_ready !== 1'b1) $fatal(1,"read not ready");
    @(posedge clk); #1;
`ifdef IDENTITY_MMIO
    if (rsp_valid !== 1'b1)
`else
    if (rsp_valid !== 1'b1 || rsp_error !== expected_error)
`endif
      $fatal(1,"bad response at %h",address);
    value = rsp_data;
    if (address == 16'd24 && !expected_error)
      for (int g=0;g<5;g++)
        if (bad_valid[g] !== 1'b1 || bad_error[g] !== 1'b0 || bad_data[g] !== 32'b0)
          $fatal(1,"invalid RTL parameters produced a usable guard");
`ifdef IDENTITY_MMIO
    if (expected_error && value !== 32'hffffffff)
`else
    if (expected_error && value !== 32'b0)
`endif
      $fatal(1,"incorrect error data");
    @(negedge clk); req_valid = 0;
  endtask
  task automatic rd(input int unsigned address, output logic [31:0] value);
    transfer(address[15:0],4'hf,1'b0,value);
  endtask

  logic [31:0] value, before_seq, after_seq, saved_history;
  integer fd;
  string dump_path;
  initial begin
    repeat (2) @(negedge clk);
    cold_reset_n = 1;
    rd(24,value);
    if (value !== 0) $fatal(1,"identity valid without context");
    @(negedge clk); context_valid = 1;
    repeat (2) @(negedge clk);
    rd(0,value);
    if (value !== 32'h31444941) $fatal(1,"magic");
    rd(28,value);
    if (value !== 1) $fatal(1,"missing context publication");
    rd(32,value);
    if (value !== ID_SOURCE[31:0]) $fatal(1,"source digest byte order");
    rd(64,value);
    if (value !== ID_BUILD[31:0]) $fatal(1,"build digest byte order");
    rd(24,before_seq);
    rd(156,saved_history);
    repeat (4) begin
      rd(156,value);
      if (value !== saved_history) $fatal(1,"destructive health read");
    end
    rd(24,after_seq);
    if (before_seq !== after_seq) $fatal(1,"read changed publication");

    // Actual torn read across supervisor START/OPENING/READY transitions.
    rd(24,before_seq);
    for (int k=0;k<32;k++) rd(4*k,value);
    @(negedge clk); cmd_valid = 1;
    @(negedge clk); cmd_valid = 0;
    repeat (2) @(negedge clk); stop_ack = 0;
    repeat (2) @(negedge clk);
    for (int k=32;k<64;k++) rd(4*k,value);
    rd(24,after_seq);
    if (before_seq == after_seq || after_seq == 0)
      $fatal(1,"torn read was not distinguishable");
    rd(152,value);
    if (value[10:9] !== 2'b11 || value[3:1] !== 3'd1 ||
        value[6:4] !== 3'd1 || value[0] !== 1'b1)
      $fatal(1,"supervisor READY health packing");

    // Actual bus transcript for C++: six discovery reads, guard, 64 words, guard.
    if (!$value$plusargs("DUMP=%s",dump_path)) $fatal(1,"DUMP is required");
    fd = $fopen(dump_path,"w");
    if (fd == 0) $fatal(1,"cannot open dump");
    for (int k=0;k<6;k++) begin
      rd(4*k,value); $fwrite(fd,"%08x\n",value);
    end
    rd(24,before_seq); $fwrite(fd,"%08x\n",before_seq);
    for (int k=0;k<64;k++) begin
      rd(4*k,value); $fwrite(fd,"%08x\n",value);
    end
    rd(24,after_seq); $fwrite(fd,"%08x\n",after_seq);
    $fclose(fd);
    if (before_seq == 0 || before_seq !== after_seq)
      $fatal(1,"positive transcript changed");

    @(negedge clk); ecc_fault = 1;
    repeat (3) @(negedge clk); ecc_fault = 0;
    repeat (2) @(negedge clk);
    rd(156,saved_history);
    if (saved_history[2] !== 1'b1 || saved_history[18] !== 1'b1)
      $fatal(1,"missing real supervisor ECC history/pending");
    repeat (3) begin
      rd(156,value);
      if (value !== saved_history) $fatal(1,"read cleared nonzero fault state");
    end
    transfer(16'h0001,4'hf,1'b1,value);
    transfer(16'h0100,4'hf,1'b1,value);
    transfer(16'h0000,4'h7,1'b1,value);
    transfer(16'hxx00,4'hf,1'b1,value);
    @(negedge clk); health_valid = 1'bx;
    repeat (2) @(negedge clk);
    for (int k=38;k<=42;k++) begin
      rd(4*k,value);
      if (value !== 0) $fatal(1,"unknown health not invalidated");
    end
    @(negedge clk); health_valid = 1;
    repeat (2) @(negedge clk);

    // Context loss and replacement invalidate the SAME accepted read edge.
    @(negedge clk);
    context_valid = 0; req_valid = 1; req_address = 16'd28; req_byteenable = 4'hf;
    @(posedge clk); #1;
`ifdef IDENTITY_MMIO
    if (rsp_valid !== 1 || rsp_data[0] !== 0)
`else
    if (rsp_valid !== 1 || rsp_error !== 0 || rsp_data[0] !== 0)
`endif
      $fatal(1,"same-edge invalidation");
    @(negedge clk); req_valid = 0; context_valid = 1'bx;
    rd(24,value);
    if (value !== 0) $fatal(1,"unknown context guard");
    @(negedge clk);
    context_valid = 1; session = session + 128'd1; epoch = 64'd10;
    req_valid = 1; req_address = 16'd28;
    @(posedge clk); #1;
    if (rsp_valid !== 1 || rsp_data[0] !== 0)
      $fatal(1,"new context exposed an old bank");
    @(negedge clk); req_valid = 0;
    rd(28,value);
    if (value !== 1) $fatal(1,"new context did not publish");
    rd(24,value);
    if (value == 0 || value == after_seq) $fatal(1,"context sequence stale");

    // Boundary injection avoids a billions-of-cycles counter test.
    @(negedge clk); force `IDENTITY_DUT.sequence_q = 32'hffffffff;
    rd(24,value);
    if (value !== 32'hffffffff) $fatal(1,"maximum sequence unavailable");
    @(negedge clk); health_valid = 0;
    @(posedge clk); #1;
    @(negedge clk); release `IDENTITY_DUT.sequence_q;
    rd(28,value);
    if (value !== 2) $fatal(1,"sequence did not fail closed");
    @(negedge clk); health_valid = 1;
    rd(24,value);
    if (value !== 0) $fatal(1,"exhausted sequence recovered");

    @(negedge clk); req_valid = 1; req_address = 0;
    @(posedge clk); #1;
    if (rsp_valid !== 1) $fatal(1,"missing pre-reset response");
    cold_reset_n = 0; context_valid = 0; req_valid = 0; stop_ack = 1;
    session = session + 128'd1; epoch = 64'd11;
    #1;
    if (rsp_valid !== 0) $fatal(1,"reset did not cancel response");
    repeat (2) @(negedge clk); cold_reset_n = 1;
    rd(24,value);
    if (value !== 0) $fatal(1,"reset retained identity validity");
    @(negedge clk); context_valid = 1;
    repeat (2) @(negedge clk);
    rd(28,value);
    if (value !== 1) $fatal(1,"fresh post-reset context failed");
    $display("A10_IDENTITY_RTL_PASS");
    $finish;
  end
endmodule
`default_nettype wire

`undef IDENTITY_DUT
