`timescale 1ns/1ps
module kernel_ddr_adapter_tb;
parameter CMD_DEPTH=4, READ_DEPTH=8;
logic [0:0] clk;
logic [0:0] cold_reset_n;
logic [0:0] memory_ready;
logic [0:0] backend_init_failed;
logic [0:0] backend_ecc_interrupt;
logic [0:0] quiesce_req;
logic [0:0] k_read;
logic [0:0] k_write;
logic [34:0] k_address;
logic [63:0] k_writedata;
logic [7:0] k_byteenable;
logic [0:0] k_burstcount;
logic [0:0] k_waitrequest;
logic [63:0] k_readdata;
logic [0:0] k_readdatavalid;
logic [0:0] k_writeack;
logic [24:0] d_address;
logic [0:0] d_read;
logic [0:0] d_write;
logic [511:0] d_writedata;
logic [63:0] d_byteenable;
logic [0:0] d_burstcount;
logic [0:0] d_waitrequest;
logic [511:0] d_readdata;
logic [0:0] d_readdatavalid;
logic [0:0] d_readdataerror;
logic [0:0] fault;
logic [7:0] fault_code;
logic [34:0] fault_address;
logic [0:0] fault_address_valid;
logic [0:0] quiescing;
logic [0:0] drained;
kernel_ddr_adapter #(.CMD_DEPTH(CMD_DEPTH), .READ_DEPTH(READ_DEPTH)) dut (.*);
import "DPI-C" context task run_adapter_test(output int result);
export "DPI-C" task exchange_adapter;
task exchange_adapter(
  input longint unsigned p_clk,
  input longint unsigned p_cold_reset_n,
  input longint unsigned p_memory_ready,
  input longint unsigned p_backend_init_failed,
  input longint unsigned p_backend_ecc_interrupt,
  input longint unsigned p_quiesce_req,
  input longint unsigned p_k_read,
  input longint unsigned p_k_write,
  input longint unsigned p_k_address,
  input longint unsigned p_k_writedata,
  input longint unsigned p_k_byteenable,
  input longint unsigned p_k_burstcount,
  output longint unsigned p_k_waitrequest,
  output longint unsigned p_k_readdata,
  output longint unsigned p_k_readdatavalid,
  output longint unsigned p_k_writeack,
  output longint unsigned p_d_address,
  output longint unsigned p_d_read,
  output longint unsigned p_d_write,
  output bit [511:0] p_d_writedata,
  output longint unsigned p_d_byteenable,
  output longint unsigned p_d_burstcount,
  input longint unsigned p_d_waitrequest,
  input bit [511:0] p_d_readdata,
  input longint unsigned p_d_readdatavalid,
  input longint unsigned p_d_readdataerror,
  output longint unsigned p_fault,
  output longint unsigned p_fault_code,
  output longint unsigned p_fault_address,
  output longint unsigned p_fault_address_valid,
  output longint unsigned p_quiescing,
  output longint unsigned p_drained);
  clk = p_clk;
  cold_reset_n = p_cold_reset_n;
  memory_ready = p_memory_ready;
  backend_init_failed = p_backend_init_failed;
  backend_ecc_interrupt = p_backend_ecc_interrupt;
  quiesce_req = p_quiesce_req;
  k_read = p_k_read;
  k_write = p_k_write;
  k_address = p_k_address;
  k_writedata = p_k_writedata;
  k_byteenable = p_k_byteenable;
  k_burstcount = p_k_burstcount;
  d_waitrequest = p_d_waitrequest;
  d_readdata = p_d_readdata;
  d_readdatavalid = p_d_readdatavalid;
  d_readdataerror = p_d_readdataerror;
  #1; // Allow combinational and NBA regions to settle before sampling.
  if ($isunknown({k_waitrequest,k_readdata,k_readdatavalid,k_writeack,d_address,d_read,d_write,d_writedata,d_byteenable,d_burstcount,fault,fault_code,fault_address,fault_address_valid,quiescing,drained}))
    $fatal(1, "unknown adapter output before DPI conversion");
  p_k_waitrequest = k_waitrequest;
  p_k_readdata = k_readdata;
  p_k_readdatavalid = k_readdatavalid;
  p_k_writeack = k_writeack;
  p_d_address = d_address;
  p_d_read = d_read;
  p_d_write = d_write;
  p_d_writedata = d_writedata;
  p_d_byteenable = d_byteenable;
  p_d_burstcount = d_burstcount;
  p_fault = fault;
  p_fault_code = fault_code;
  p_fault_address = fault_address;
  p_fault_address_valid = fault_address_valid;
  p_quiescing = quiescing;
  p_drained = drained;
endtask
int result;
initial begin
  run_adapter_test(result);
  if (result != 0) $fatal(1, "adapter scoreboard failed");
  $finish;
end
endmodule
