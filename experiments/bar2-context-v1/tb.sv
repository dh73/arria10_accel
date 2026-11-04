module tb;
 logic pcie_clk=0,kernel_clk=0,common_cold_reset_n=0;
 always #7 pcie_clk=~pcie_clk;always #5 kernel_clk=~kernel_clk;
 logic read=0,write=0;logic [63:0] address=0;logic[31:0] writedata=0;logic[3:0] byteenable=15;
 wire waitrequest,readdatavalid,invalid_access;wire[31:0] readdata;
 logic ddr_read=0,ddr_write=0,ddr_waitrequest=0,ddr_readdatavalid=0;logic[63:0] ddr_byteenable=0;
 wire cra_read,cra_write,control_cmd_valid;wire[2:0] control_cmd_op;
 wire fence_ready,fence_settled,fence_fault,write_pending;
 wire[29:0] cra_address;wire[63:0] cra_writedata;wire[7:0] cra_byteenable;
 wire provisioned_valid,provisioned_fault;wire [127:0] provisioned_session;wire [63:0] provisioned_epoch;
 shell_bar2_context_v1 dut(.pcie_clk,.kernel_clk,.common_cold_reset_n,
 .ddr_read,.ddr_write,.ddr_waitrequest,.ddr_readdatavalid,.ddr_byteenable,
 .provisioned_valid,.provisioned_fault,.provisioned_session,.provisioned_epoch,
 .context_valid(provisioned_valid),.health_valid(1'b1),.session(provisioned_session),.epoch(provisioned_epoch),
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
 initial begin
  logic[31:0] v;
  repeat(3)@(negedge pcie_clk);common_cold_reset_n=1;repeat(5)@(negedge pcie_clk);
  rd(768,v);if(v!=32'ha10e0001)$fatal(1,"context signature");
  rd(772,v);if(v!=0)$fatal(1,"unprovisioned status");
  for(integer k=0;k<6;k++)begin
   wr(776+4*k,32'(k+1),15);
   if(provisioned_valid || provisioned_epoch!=0 || provisioned_session!=0)$fatal(1,"early context");
  end
  wr(768,32'ha10e0001,15);rd(772,v);
  if(v!=1 || !provisioned_valid || provisioned_fault || provisioned_epoch!==64'h0000000200000001 ||
     provisioned_session!==128'h00000006000000050000000400000003)$fatal(1,"context commit");
  rd(64'h100000308,v);if(v!=1)$fatal(1,"context high-base normalization");
  rd(800,v);if(v!=32'hffffffff)$fatal(1,"context overrun");
  rd(640,v);if(v!=32'ha10d0001)$fatal(1,"metrics decode");
  @(negedge kernel_clk);ddr_write=1;ddr_byteenable=64'hf;
  repeat(9)@(negedge kernel_clk);ddr_write=0;
  wr(640,32'ha10d0001,15);rd(648,v);if(v!=1)$fatal(1,"snapshot sequence");
  rd(672,v);if(v!=9)$fatal(1,"accepted writes %d",v);
  rd(680,v);if(v!=36)$fatal(1,"enabled bytes %d",v);
  rd(688,v);if(v!=0)$fatal(1,"stall count");
  wr(640,32'ha10d0001,1);rd(648,v);if(v!=1)$fatal(1,"partial write captured");
  // High bits are HIP BAR base, normalized by the existing frontend contract.
  rd(64'h100000280,v);if(v!=32'ha10d0001)$fatal(1,"BAR relative address");
  rd(720,v);if(v!=32'hffffffff)$fatal(1,"window overrun");
  rd(636,v);if(v!=32'hffffffff)$fatal(1,"window underrun");
  wr(776,99,15);rd(772,v);
  if(v!=2 || provisioned_valid || !provisioned_fault || provisioned_epoch!==64'h0000000200000001)$fatal(1,"context replacement");
  $display("BAR2_CONTEXT_PASS cdc atomic immutable decode metrics_isolation");$finish;
 end
endmodule
