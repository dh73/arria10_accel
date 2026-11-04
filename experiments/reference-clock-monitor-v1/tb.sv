`timescale 1ns/1ps
module tb;
 logic ref_clk=0,monitor_clk=0,reset_n=0,enabled=1;
 logic qualified,fault;
 always #5 monitor_clk=~monitor_clk;
 always #2.5 if(enabled) ref_clk=~ref_clk;
 // Divider MSB toggles every 32 reference cycles: 16 monitor cycles.
 reference_clock_monitor #(.DIV_LOG2(6),.MIN_TICKS(14),.MAX_TICKS(18),.GOOD_INTERVALS(3)) dut(.*);
 task automatic reset;
  reset_n=0;repeat(4) @(negedge monitor_clk);reset_n=1;
 endtask
 task automatic qualify;
  repeat(90) @(negedge monitor_clk);
  if(!qualified || fault) $fatal(1,"normal clock did not qualify");
 endtask
 initial begin
  reset();qualify();
  enabled=0;
  repeat(24) @(negedge monitor_clk);
  if(qualified || !fault) $fatal(1,"clock loss not contained");
  enabled=1;repeat(90) @(negedge monitor_clk);
  if(qualified || !fault) $fatal(1,"clock return erased fault");
  reset();qualify();
  reset_n=0;#1;
  if(qualified || fault) $fatal(1,"external reset failed");
  $display("REFERENCE_CLOCK_MONITOR_PASS");$finish;
 end
endmodule
