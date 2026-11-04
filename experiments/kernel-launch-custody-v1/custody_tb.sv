module custody_tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,backend_reset_n=0,stop_req=0,write_pending=0;
 logic cra_read=0,cra_write=0,cra_waitrequest=0,cra_readdatavalid=0;
 logic [29:0] cra_address=0;
 logic [63:0] cra_writedata=0,cra_readdata=0;
 logic [7:0] cra_byteenable=8'hff;
 wire write_permit,busy,kernel_idle,kernel_stop_ack,fault,launch_owned,launch_kernel,read_pending;
`include "kernel_launch_source_binding.svh"
 kernel_launch_custody #(.COPY_SHA(EXPECTED_COPY_SHA),.TRIAD_SHA(EXPECTED_TRIAD_SHA)) dut(.*);
 wire refused_idle,refused_permit;
 kernel_launch_custody unqualified(.clk,.cold_reset_n,.backend_reset_n,.stop_req,.write_pending,
   .cra_read,.cra_write,.cra_address,.cra_writedata,.cra_readdata,.cra_byteenable,.cra_waitrequest,.cra_readdatavalid,
   .write_permit(refused_permit),.kernel_idle(refused_idle),.busy(),.kernel_stop_ack(),.fault(),.launch_owned(),.launch_kernel(),.read_pending());
 task automatic reset;
  @(negedge clk);cold_reset_n=0;backend_reset_n=0;cra_read=0;cra_write=0;
  cra_readdatavalid=0;write_pending=0;stop_req=0;cra_waitrequest=0;cra_byteenable='1;
  repeat(3)@(negedge clk);cold_reset_n=1;backend_reset_n=1;
  repeat(4)@(negedge clk);
  assert(kernel_idle&&!fault&&write_permit&&!refused_idle&&!refused_permit)else $fatal(1,"reset/profile gate");
 endtask
 task automatic start_launch(input bit kernel=0);
  @(negedge clk);write_pending=1;cra_write=1;cra_address=kernel?264:8;cra_writedata=1;cra_waitrequest=1;
  #1;assert(!kernel_idle&&busy)else $fatal(1,"pending start idle gap");
  stop_req=1;
  repeat(3)begin @(posedge clk);#1;assert(!kernel_idle&&!kernel_stop_ack&&!launch_owned&&!write_permit)else $fatal(1,"stalled start");end
  @(negedge clk);cra_waitrequest=0;
  @(posedge clk);#1;write_pending=0;cra_write=0;
  #1;assert(launch_owned&&!kernel_idle&&kernel_stop_ack&&!fault&&launch_kernel==kernel)else $fatal(1,"start handover gap");
  @(negedge clk);stop_req=0;
 endtask
 task automatic read_reply(input int address,input logic [63:0] data,input bit immediate=0);
  @(negedge clk);cra_read=1;cra_address=30'(address);cra_readdata=data;cra_readdatavalid=immediate;
  @(posedge clk);#1;
  @(negedge clk);cra_read=0;if(immediate)cra_readdatavalid=0;
  if(!immediate)begin
   repeat(3)begin @(posedge clk);#1;assert(read_pending&&!kernel_idle)else $fatal(1,"lost read identity");end
   @(negedge clk);cra_readdatavalid=1;
   @(posedge clk);#1;
  end
  @(negedge clk);cra_readdatavalid=0;#1;
 endtask
 int scenarios=0;
 initial begin
  for(int k=0;k<2;k++)for(int immediate=0;immediate<2;immediate++)begin
   reset();start_launch(k!=0);
   read_reply(k*256,64'h2,immediate!=0); // stale finished status is never credit.
   assert(launch_owned&&!fault&&!kernel_idle)else $fatal(1,"status retired launch");
   read_reply(k*256+48,0,immediate!=0);
   assert(launch_owned&&!fault&&!kernel_idle)else $fatal(1,"zero retired launch");
   stop_req=1;read_reply(k*256+48,1,immediate!=0);
   assert(!launch_owned&&kernel_idle&&kernel_stop_ack&&!write_permit&&!fault)else $fatal(1,"matching finish failed");
   scenarios++;
  end
  reset();start_launch();read_reply(304,1);
  assert(fault&&launch_owned&&!kernel_idle)else $fatal(1,"wrong kernel");scenarios++;
  reset();start_launch();read_reply(48,2,1);
  assert(fault&&launch_owned&&!kernel_idle)else $fatal(1,"count2");scenarios++;
  reset();start_launch();read_reply(48,64'h100000001,1);
  assert(fault&&launch_owned&&!kernel_idle)else $fatal(1,"reserved bits");scenarios++;
  reset();read_reply(48,1,1);
  assert(fault&&!kernel_idle)else $fatal(1,"completion without owner");scenarios++;
  reset();start_launch();
  @(negedge clk);cra_write=1;cra_address=264;cra_writedata=1;
  @(posedge clk);#1;assert(fault&&launch_owned)else $fatal(1,"duplicate start");scenarios++;
  reset();start_launch();
  @(negedge clk);cra_read=1;cra_address=48;
  @(posedge clk);@(negedge clk);cra_read=0;cra_write=1;cra_address=264;cra_writedata=1;cra_readdatavalid=1;cra_readdata=1;
  @(posedge clk);#1;assert(fault&&launch_owned&&read_pending&&!kernel_idle)else $fatal(1,"simultaneous retirement/start");scenarios++;
  reset();@(negedge clk);cra_readdatavalid=1;
  @(posedge clk);#1;assert(fault&&!kernel_idle)else $fatal(1,"unsolicited reply");scenarios++;
  reset();start_launch();
  @(negedge clk);backend_reset_n=0;#1;backend_reset_n=1;
  repeat(5)@(negedge clk);
  assert(fault&&launch_owned&&!kernel_idle&&!write_permit&&!kernel_stop_ack)else $fatal(1,"epoch fault lost custody");scenarios++;
  reset();stop_req=1;#1;
  assert(!write_permit&&kernel_stop_ack&&kernel_idle)else $fatal(1,"same-edge stop admission");scenarios++;
  $display("KERNEL_LAUNCH_CUSTODY_PASS scenarios=%0d",scenarios);$finish;
 end
endmodule
