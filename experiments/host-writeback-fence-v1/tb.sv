module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,context_valid=1,admission_closed=0,local_drained=0;
 logic [127:0] session=128'h123456789abcdef0_0123456789abcdef;
 logic [63:0] epoch=64'hfedcba9876543210;
 logic read=0,write=0;logic [4:0] address=0;
 logic [31:0] writedata=0;logic [3:0] byteenable=15;
 wire readdatavalid,ready,settled,fault;wire [31:0] readdata;
 logic [191:0] observed;
 host_writeback_fence dut(.*);
 task tick;@(posedge clk);#1;endtask
 task reset;
  @(negedge clk);cold_reset_n=0;read=0;write=0;byteenable=15;
  admission_closed=0;local_drained=0;tick();
  @(negedge clk);epoch=epoch+1;cold_reset_n=1;tick();
 endtask
 task rd(input int a);
  @(negedge clk);address=5'(a);read=1;tick();
  if(!readdatavalid)$fatal(1,"missing read response");
  @(negedge clk);read=0;
 endtask
 task wr(input int a,input logic[31:0] d);
  @(negedge clk);address=5'(a);writedata=d;write=1;tick();
  @(negedge clk);write=0;
 endtask
 task arm;
  @(negedge clk);admission_closed=1;local_drained=1;tick();
  if(!ready||settled)$fatal(1,"local drain fabricated settlement");
 endtask
 task capture;
  rd(0);if(readdata!=1)$fatal(1,"not ready");
  for(int i=0;i<6;i++)begin rd(4+4*i);observed[i*32+:32]=readdata;end
 endtask
 task echo_context;
  for(int i=0;i<6;i++)wr(4+4*i,observed[i*32+:32]);
 endtask
 initial begin
  reset();repeat(3)tick();if(ready||settled)$fatal(1,"unclosed ready");
  arm();repeat(3)tick();if(settled)$fatal(1,"empty queue became settlement");
  capture();echo_context();wr(28,32'ha10f0001);
  if(!settled||fault)$fatal(1,"valid ordered acknowledgement rejected");
  @(negedge clk);local_drained=0;#1;
  if(settled)$fatal(1,"late producer not immediately contained");tick();
  @(negedge clk);local_drained=1;tick();if(!fault||settled)$fatal(1,"late producer reopened");
  reset();arm();wr(28,32'ha10f0001);if(!fault||settled)$fatal(1,"commit before read");
  reset();arm();capture();wr(4,observed[31:0]);wr(28,32'ha10f0001);
  if(!fault||settled)$fatal(1,"partial echo accepted");
  reset();arm();capture();observed[0]=!observed[0];echo_context();wr(28,32'ha10f0001);
  if(!fault||settled)$fatal(1,"stale epoch accepted");
  reset();arm();capture();@(negedge clk);session=session+1;#1;
  if(ready||settled)$fatal(1,"context change ignored");tick();if(!fault)$fatal(1,"context fault absent");
  $display("HOST_WRITEBACK_FENCE_PASS ordered_ack late_producer missing_read partial_echo stale_epoch context_loss");$finish;
 end
endmodule
