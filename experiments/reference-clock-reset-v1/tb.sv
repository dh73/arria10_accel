`timescale 1ns/1ps
module tb;
 logic ref_clk=0,monitor_clk=0,reset_n=0,enabled=1;
 logic qualified,fault,global_reset_n;
 always #10 monitor_clk=~monitor_clk;
 always #3.333 if(enabled) ref_clk=~ref_clk;
 // 150 MHz reference divided to an edge every 32 cycles; independent 50 MHz
 // monitor observes intervals of 10 or 11 ticks plus CDC phase uncertainty.
 reference_clock_monitor #(.DIV_LOG2(6),.MIN_TICKS(9),.MAX_TICKS(13),.GOOD_INTERVALS(3)) monitor(.*);
 c126_reset_release #(.ALLOW_RELEASE(1),.HOLD_REF_CYCLES(16)) conditioner(
 .ref_clk,.external_reset_n(reset_n),.ref_clock_good(qualified),.global_reset_n);
 task automatic restart;
  reset_n=0;enabled=1;repeat(4) @(negedge monitor_clk);reset_n=1;
  repeat(85) @(negedge monitor_clk);
  if(!qualified || fault || !global_reset_n) $fatal(1,"qualified release missing");
 endtask
 initial begin
  for(int level=0;level<2;level++) begin
   restart();
   wait(ref_clk==level);enabled=0;
   repeat(18) @(negedge monitor_clk);
   if(qualified || !fault || global_reset_n) $fatal(1,"stopped reference failed reset assertion");
   enabled=1;repeat(85) @(negedge monitor_clk);
   if(qualified || !fault || global_reset_n) $fatal(1,"clock return re-released DDR without recovery");
  end
  restart();reset_n=0;#1;
  if(global_reset_n) $fatal(1,"external reset failed");
  $display("REFERENCE_CLOCK_DDR_RESET_PASS stopped_levels=2");$finish;
 end
endmodule
