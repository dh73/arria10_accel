module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,cmd_valid=0;logic [2:0] cmd_op=0;
 logic read=0,write=0;logic [5:0] address=0;logic [31:0] writedata=0;
 wire launch_permit,host_submit_permit,kernel_stop_req,host_stop_req,adapter_quiesce_req;
 wire release_ready,fault_latched,cmd_ready,cmd_done,cmd_accepted,admission_reopen;
 wire [2:0] state_status,phase_status;wire [3:0] cmd_reason;
 wire ready,settled,fault,readdatavalid;wire [31:0] readdata;
 logic kernel_stop_ack=1,host_stop_ack=1;
 logic producer_drained=1,tx_empty=1;
 logic [255:0] observed,previous;
 int opens=0;
 // Coherent source-status fixture; no DMA/CDC/physical closure claimed.
 always @(posedge clk)begin
  kernel_stop_ack<=kernel_stop_req;host_stop_ack<=host_stop_req;
  if(admission_reopen)opens<=opens+1;
 end
 platform_supervisor_fence_round #(.ADDR_W(41)) supervisor(
 .clk,.cold_reset_n,.memory_ready(1'b1),.backend_init_failed(1'b0),.backend_ecc_interrupt(1'b0),
 .adapter_fault(1'b0),.adapter_fault_code(8'b0),.adapter_fault_address(41'b0),
 .adapter_fault_address_valid(1'b0),.adapter_quiescing(adapter_quiesce_req),.adapter_drained(1'b1),
 .kernel_status_valid(1'b1),.kernel_stop_ack,.kernel_idle(1'b1),.kernel_fault(1'b0),
 .host_status_valid(1'b1),.host_stop_ack,.host_dma_drained(producer_drained),.host_desc_drained(producer_drained),
 .host_writeback_drained(settled),.host_fault(fault),.external_stop(1'b0),
 .cmd_valid,.cmd_op,.clear_valid(1'b0),.clear_mask(16'b0),
 .launch_permit,.host_submit_permit,.kernel_stop_req,.host_stop_req,.adapter_quiesce_req,
 .state_status,.phase_status,.release_ready,.fault_latched,.cmd_ready,.cmd_done,.cmd_accepted,.cmd_reason,.admission_reopen);
 host_writeback_fence_round fence(.clk,.cold_reset_n,.context_valid(1'b1),
 .session(128'h123456789abcdef0123456789abcdef0),.epoch(64'd9),
 .admission_closed(host_stop_ack),.local_drained(producer_drained),.tx_checkpoint_empty(tx_empty),
 .stop_requested(host_stop_req),.reopen(admission_reopen),.read,.write,.address,.writedata,
 .byteenable(4'hf),.readdatavalid,.readdata,.ready,.settled,.fault);
 task tick;@(posedge clk);#1;endtask
 task command(input logic [2:0] op);
  @(negedge clk);cmd_op=op;cmd_valid=1;tick();@(negedge clk);cmd_valid=0;
 endtask
 task rd(input int a);
  @(negedge clk);address=6'(a);read=1;tick();if(!readdatavalid)$fatal(1,"no response");
  @(negedge clk);read=0;
 endtask
 task wr(input int a,input logic [31:0] d);
  @(negedge clk);address=6'(a);writedata=d;write=1;tick();@(negedge clk);write=0;
 endtask
 task handshake;
  rd(0);if(readdata!==1)$fatal(1,"fence unavailable");
  for(int i=0;i<8;i++)begin rd(4+4*i);observed[i*32+:32]=readdata;end
  for(int i=0;i<8;i++)wr(4+4*i,observed[i*32+:32]);
  wr(36,32'ha10f0001);repeat(3)tick();
  if(!release_ready||!settled||fault_latched)$fatal(1,"barrier unavailable after handshake");
 endtask
 task running;
  repeat(4)tick();
  if(!launch_permit||!host_submit_permit||fault_latched||fault||settled||phase_status!=1)
   $fatal(1,"failed to reopen cleanly phase=%d fault=%b fence=%b",phase_status,fault_latched,fault);
 endtask
 initial begin
  repeat(2)tick();@(negedge clk);cold_reset_n=1;repeat(3)tick();
  command(0);if(!cmd_done||cmd_accepted||cmd_reason!=5||launch_permit)$fatal(1,"START bypassed fence");
  handshake();previous=observed;command(0);running();
  @(negedge clk);producer_drained=0;tx_empty=0;repeat(3)tick();
  command(2);repeat(4)tick();if(ready||settled||release_ready||fault_latched)$fatal(1,"stop debt mishandled");
  @(negedge clk);producer_drained=1;repeat(3)tick();if(ready)$fatal(1,"TX debt ignored");
  @(negedge clk);tx_empty=1;repeat(2)tick();
  handshake();if(observed[255:192]!==previous[255:192]+64'd1)$fatal(1,"round not advanced");
  command(1);running();
  if(opens!=2)$fatal(1,"unexpected consumption count %d",opens);
  command(2);repeat(3)tick();handshake();
  if(observed[255:192]!==64'd3)$fatal(1,"third round missing");
  command(1);running();if(opens!=3)$fatal(1,"repeat resume consumption");
  $display("SUPERVISOR_FENCE_ROUND_PASS startup_blocked startup resume repeat_resume delayed_producer delayed_tx opens=3");$finish;
 end
endmodule
