module tb;
 logic pcie_clk=0,kernel_clk=0,common_cold_reset_n=0;
 always #7 pcie_clk=~pcie_clk;always #5 kernel_clk=~kernel_clk;
 logic read=0,write=0;logic [63:0] address=0;logic[31:0] writedata=0;logic[3:0] byteenable=15;
 wire waitrequest,readdatavalid,invalid_access;wire[31:0] readdata;
 logic ddr_read=0,ddr_write=0,ddr_waitrequest=0,ddr_readdatavalid=0;logic[63:0] ddr_byteenable=0;
 wire cra_read,cra_write,control_cmd_valid;wire[2:0] control_cmd_op;
 wire fence_ready,fence_settled,fence_fault,write_pending;
 wire[29:0] cra_address;wire[63:0] cra_writedata;wire[7:0] cra_byteenable;
 shell_bar2_metrics_v1 dut(.pcie_clk,.kernel_clk,.common_cold_reset_n,
 .ddr_read,.ddr_write,.ddr_waitrequest,.ddr_readdatavalid,.ddr_byteenable,
 .context_valid(1'b1),.health_valid(1'b1),.session(128'd1),.epoch(64'd1),
 .control_cmd_valid,.control_cmd_op,.control_cmd_ready(1'b1),.control_cmd_done(1'b0),.control_cmd_accepted(1'b0),.control_cmd_reason(4'b0),
 .fence_admission_closed(1'b1),.fence_local_drained(1'b1),.fence_tx_checkpoint_empty(1'b1),.fence_stop_requested(1'b1),.fence_reopen(1'b0),.fence_ready,.fence_settled,.fence_fault,
 .state_status(3'b0),.phase_status(3'b0),.release_ready(1'b0),.fault_latched(1'b0),.launch_permit(1'b0),.host_submit_permit(1'b0),
 .fault_history(16'b0),.fault_pending(16'b0),.first_fault_code(16'b0),.first_adapter_code(8'b0),.first_adapter_address(41'b0),.first_adapter_address_valid(1'b0),
 .read,.write,.address,.writedata,.byteenable,.waitrequest,.readdatavalid,.readdata,.invalid_access,.write_pending,
 .cra_read,.cra_write,.cra_address,.cra_writedata,.cra_byteenable,.cra_waitrequest(1'b0),.cra_readdatavalid(1'b0),.cra_readdata(64'b0));
 always @(posedge kernel_clk)if(common_cold_reset_n&&(cra_read||cra_write||control_cmd_valid||write_pending||fence_settled))
  $fatal(1,"metrics access affected lifecycle/kernel control");
 task rd(input longint unsigned a,output logic[31:0] v);
  @(negedge pcie_clk);address=a;read=1;
  do @(posedge pcie_clk);while(waitrequest);
  @(negedge pcie_clk);read=0;
  wait(readdatavalid);v=readdata;@(negedge pcie_clk);
 endtask
 task wr(input longint unsigned a,input logic[31:0] v,input logic[3:0] mask);
  @(negedge pcie_clk);address=a;write=1;writedata=v;byteenable=mask;
  do @(posedge pcie_clk);while(waitrequest);
  @(negedge pcie_clk);write=0;byteenable=15;wait(!waitrequest);
 endtask
 import "DPI-C" context task run_snapshot_host(output int result);
 export "DPI-C" task control_reset;
 export "DPI-C" task control_get;
 export "DPI-C" task control_put;
 export "DPI-C" task control_traffic;
 task control_reset;
  @(negedge pcie_clk);common_cold_reset_n=0;read=0;write=0;ddr_read=0;ddr_write=0;
  ddr_waitrequest=0;ddr_readdatavalid=0;
  repeat(3)@(negedge pcie_clk);common_cold_reset_n=1;repeat(5)@(negedge pcie_clk);
 endtask
 task control_get(input longint unsigned a,output int unsigned d);rd(a,d);endtask
 task control_put(input longint unsigned a,input int unsigned d);wr(a,d,15);endtask
 task control_traffic;
  @(negedge kernel_clk);ddr_write=1;ddr_byteenable=64'hf;
  repeat(9)@(negedge kernel_clk);ddr_waitrequest=1;
  repeat(6)@(negedge kernel_clk);ddr_write=0;ddr_waitrequest=0;ddr_read=1;
  @(negedge kernel_clk);ddr_read=0;ddr_readdatavalid=1;
  @(negedge kernel_clk);ddr_readdatavalid=0;
 endtask
 initial begin
  int result;run_snapshot_host(result);
  if(result!=0)$fatal(1,"host snapshot integration failed");
  $display("DDR_HOST_RTL_PASS counters CDC host_decoder rate_interval uncertainty");$finish;
 end
endmodule
