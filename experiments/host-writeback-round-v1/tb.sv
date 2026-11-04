module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,context_valid=1,admission_closed=1,local_drained=1;
 logic tx_checkpoint_empty=1,stop_requested=1,reopen=0;
 logic [127:0] session=128'h123456789abcdef0_0123456789abcdef;
 logic [63:0] epoch=64'hfedcba9876543210;
 logic read=0,write=0;logic [5:0] address=0;
 logic [31:0] writedata=0;logic [3:0] byteenable=15;
 wire readdatavalid,ready,settled,fault;wire [31:0] readdata;
 logic [255:0] observed,old_round;
 host_writeback_fence_round dut(.*);
 task tick;@(posedge clk);#1;endtask
 task reset;
  @(negedge clk);cold_reset_n=0;read=0;write=0;reopen=0;byteenable=15;
  context_valid=1;admission_closed=1;local_drained=1;tx_checkpoint_empty=1;stop_requested=1;tick();
  @(negedge clk);epoch=epoch+1;cold_reset_n=1;repeat(2)tick();
 endtask
 task rd(input int a);
  @(negedge clk);address=6'(a);read=1;tick();
  if(!readdatavalid)$fatal(1,"missing read response");
  @(negedge clk);read=0;
 endtask
 task wr(input int a,input logic[31:0] d);
  @(negedge clk);address=6'(a);writedata=d;write=1;tick();
  @(negedge clk);write=0;
 endtask
 task capture;
  rd(0);if(readdata!=1)$fatal(1,"not ready");
  for(int i=0;i<8;i++)begin rd(4+4*i);observed[i*32+:32]=readdata;end
 endtask
 task echo_context;
  for(int i=0;i<8;i++)wr(4+4*i,observed[i*32+:32]);
 endtask
 task settle;
  capture();echo_context();wr(36,32'ha10f0001);
  if(!settled||fault)$fatal(1,"valid acknowledgement rejected");
 endtask
 task open_work;
  @(negedge clk);reopen=1;tick();
  if(settled||ready||fault)$fatal(1,"consumption failed");
  @(negedge clk);reopen=0;
  repeat(3)tick();if(ready||settled)$fatal(1,"rearmed on delayed closed acknowledgement");
  @(negedge clk);stop_requested=0;admission_closed=0;local_drained=0;tick();
  if(fault||settled)$fatal(1,"normal work faulted or settled");
 endtask
 task close_work;
  @(negedge clk);stop_requested=1;admission_closed=1;local_drained=1;tx_checkpoint_empty=0;
  repeat(3)tick();if(ready||settled)$fatal(1,"no TX checkpoint");
  @(negedge clk);tx_checkpoint_empty=1;tick();
  if(!ready||fault)$fatal(1,"second stop not ready");
  @(negedge clk);tx_checkpoint_empty=0;tick();
  if(!ready||fault)$fatal(1,"fence response traffic invalidates checkpoint");
 endtask
 initial begin
  reset();settle();old_round=observed;open_work();close_work();settle();
  if(observed[191:0]!==old_round[191:0] || observed[255:192]!==old_round[255:192]+64'd1)
   $fatal(1,"context or generation mismatch");
  open_work();close_work();capture();observed=old_round;echo_context();wr(36,32'ha10f0001);
  if(!fault||settled)$fatal(1,"stale round accepted");
  reset();@(negedge clk);reopen=1;tick();if(!fault||settled)$fatal(1,"unsettled reopen accepted");
  reset();settle();@(negedge clk);local_drained=0;#1;if(settled)$fatal(1,"late producer ignored");
  tick();if(!fault)$fatal(1,"late producer not latched");
  reset();settle();open_work();@(negedge clk);session=session+1;tick();if(!fault)$fatal(1,"running context mutation ignored");
  reset();wr(36,32'ha10f0001);if(!fault||settled)$fatal(1,"commit without read accepted");
  reset();capture();wr(4,observed[31:0]);wr(36,32'ha10f0001);if(!fault||settled)$fatal(1,"partial echo accepted");
  reset();settle();@(negedge clk);reopen=1;read=1;address=0;tick();if(!fault)$fatal(1,"concurrent consumption/MMIO accepted");
  $display("HOST_WRITEBACK_ROUND_PASS startup resume stale_round late_producer context_change missing_read partial_echo consumption_collision");$finish;
 end
endmodule
