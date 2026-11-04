`timescale 1ns/1ps
module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,context_valid=0;logic[127:0]session=0;logic[63:0]epoch=0;
 wire bound,live,fault;wire[127:0]bound_session;wire[63:0]bound_epoch;
 platform_context_guard dut(.*);
 task tick;@(posedge clk);#1;endtask
 initial begin
  for(int mode=0;mode<7;mode++)begin
   @(negedge clk);cold_reset_n=0;context_valid=0;session=0;epoch=0;tick();
   @(negedge clk);cold_reset_n=1;repeat(3)tick();
   if(bound||live||fault)$fatal(1,"initial invalid context admitted");
   @(negedge clk);context_valid=1;session=128'h1234;epoch=7;tick();
   if(!bound||!live||fault)$fatal(1,"initial valid context rejected");
   repeat(3)tick();
   @(negedge clk);
   case(mode)
    0:session=128'h5678;1:epoch=8;2:context_valid=0;
    3:session=0;4:epoch=0;5:session='x;6:context_valid=1'bx;
   endcase
   #1;if(live)$fatal(1,"changed context admitted before edge");
   tick();if(!fault||live||!bound||bound_session!==128'h1234||bound_epoch!==7)$fatal(1,"binding lost");
   @(negedge clk);context_valid=1;session=128'h1234;epoch=7;repeat(3)tick();
   if(!fault||live)$fatal(1,"fault recovered without reset");
  end
  @(negedge clk);cold_reset_n=0;tick();
  @(negedge clk);session=128'h5678;epoch=8;cold_reset_n=1;tick();
  if(!live||fault||bound_session!==128'h5678||bound_epoch!==8)$fatal(1,"cold epoch did not bind");
  $display("PLATFORM_CONTEXT_GUARD_PASS cases=7");$finish;
 end
endmodule
