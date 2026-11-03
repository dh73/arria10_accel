// Drop-in composition around the UNMODIFIED kernel_ddr_adapter ports.
// memory_ready must be arria10_ddr_init.initialized, not raw calibration.
// Connect d_* through the existing initializer to EMIF; response inputs return
// from that same DDR response domain. See docs/platform_supervisor.md.
module platform_supervised_ddr_adapter #(
  parameter int CMD_DEPTH=4, READ_DEPTH=8
) (
  input logic clk, cold_reset_n,
  input logic memory_ready, backend_init_failed, backend_ecc_interrupt,
  input logic kernel_status_valid, kernel_stop_ack, kernel_idle, kernel_fault,
  input logic host_status_valid, host_stop_ack,
  input logic host_dma_drained, host_desc_drained, host_writeback_drained,
  input logic host_fault, external_stop,
  input logic cmd_valid,
  input logic [2:0] cmd_op,
  input logic clear_valid,
  input logic [15:0] clear_mask,
  input logic k_read, k_write,
  input logic [34:0] k_address,
  input logic [63:0] k_writedata,
  input logic [7:0] k_byteenable,
  input logic k_burstcount,
  output logic k_waitrequest,
  output logic [63:0] k_readdata,
  output logic k_readdatavalid, k_writeack,
  output logic [24:0] d_address,
  output logic d_read, d_write,
  output logic [511:0] d_writedata,
  output logic [63:0] d_byteenable,
  output logic d_burstcount,
  input logic d_waitrequest,
  input logic [511:0] d_readdata,
  input logic d_readdatavalid, d_readdataerror,
  output logic launch_permit, host_submit_permit,
  output logic kernel_stop_req, host_stop_req, adapter_quiesce_req,
  output logic [2:0] state_status, phase_status,
  output logic release_ready, fault_latched,
  output logic [15:0] fault_history, fault_pending, first_fault_code,
  output logic [7:0] first_adapter_code,
  output logic [34:0] first_adapter_address,
  output logic first_adapter_address_valid,
  output logic cmd_ready, cmd_done, cmd_accepted,
  output logic [3:0] cmd_reason,
  output logic clear_done,
  output logic [15:0] clear_blocked,
  output logic reset_request, epoch_advance,
  output logic adapter_fault,
  output logic [7:0] adapter_fault_code,
  output logic [34:0] adapter_fault_address,
  output logic adapter_fault_address_valid, adapter_quiescing, adapter_drained
);
  // Names deliberately identical to the supervisor's proposed control ABI.
  platform_supervisor supervisor (.*);
  kernel_ddr_adapter #(.CMD_DEPTH(CMD_DEPTH),.READ_DEPTH(READ_DEPTH)) adapter (
    .clk(clk), .cold_reset_n(cold_reset_n), .memory_ready(memory_ready),
    .backend_init_failed(backend_init_failed),
    .backend_ecc_interrupt(backend_ecc_interrupt),
    .quiesce_req(adapter_quiesce_req),
    .k_read(k_read), .k_write(k_write), .k_address(k_address),
    .k_writedata(k_writedata), .k_byteenable(k_byteenable),
    .k_burstcount(k_burstcount), .k_waitrequest(k_waitrequest),
    .k_readdata(k_readdata), .k_readdatavalid(k_readdatavalid),
    .k_writeack(k_writeack),
    .d_address(d_address), .d_read(d_read), .d_write(d_write),
    .d_writedata(d_writedata), .d_byteenable(d_byteenable),
    .d_burstcount(d_burstcount), .d_waitrequest(d_waitrequest),
    .d_readdata(d_readdata), .d_readdatavalid(d_readdatavalid),
    .d_readdataerror(d_readdataerror),
    .fault(adapter_fault), .fault_code(adapter_fault_code),
    .fault_address(adapter_fault_address),
    .fault_address_valid(adapter_fault_address_valid),
    .quiescing(adapter_quiescing), .drained(adapter_drained)
  );
endmodule
