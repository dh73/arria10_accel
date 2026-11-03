// Common EMIF user-clock domain; cold reset must include EMIF and all clients.
// Default ECC scrub covers the full 2 GiB payload aperture. Reduced range is
// for simulation only. Scheduler/host certificates retain their real obligations.
module platform_initialized_ddr #(
  parameter int CMD_DEPTH=4, READ_DEPTH=8,
  parameter logic [24:0] SCRUB_LAST_ADDRESS=25'h1ffffff
) (
  input logic clk, cold_reset_n,
  input logic cal_success, cal_fail, backend_ecc_interrupt,
  output logic memory_ready, backend_init_failed,
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
  output logic [24:0] amm_address,
  output logic amm_read, amm_write,
  output logic [511:0] amm_writedata,
  output logic [63:0] amm_byteenable,
  output logic [6:0] amm_burstcount,
  input logic amm_ready,
  input logic [511:0] amm_readdata,
  input logic amm_readdatavalid, amm_readdataerror,
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
  logic [24:0] d_address;
  logic d_read, d_write, d_burstcount, d_waitrequest;
  logic [511:0] d_writedata, d_readdata;
  logic [63:0] d_byteenable;
  logic d_readdatavalid, d_readdataerror;
  assign d_readdata = amm_readdata;
  assign d_readdatavalid = amm_readdatavalid;
  assign d_readdataerror = amm_readdataerror;

  platform_supervised_ddr_adapter #(.CMD_DEPTH(CMD_DEPTH), .READ_DEPTH(READ_DEPTH)) platform (.*);
  arria10_ddr_init #(.DATA_W(512), .ADDR_W(25), .LAST_ADDRESS(SCRUB_LAST_ADDRESS)) initializer (
    .clk(clk), .reset_n(cold_reset_n), .cal_success(cal_success), .cal_fail(cal_fail),
    .initialized(memory_ready), .init_failed(backend_init_failed),
    .client_address(d_address), .client_read(d_read), .client_write(d_write),
    .client_writedata(d_writedata), .client_byteenable(d_byteenable),
    .client_burstcount(d_burstcount), .client_waitrequest(d_waitrequest),
    .amm_ready(amm_ready), .amm_address(amm_address), .amm_read(amm_read),
    .amm_write(amm_write), .amm_writedata(amm_writedata),
    .amm_byteenable(amm_byteenable), .amm_burstcount(amm_burstcount)
  );
endmodule
