`timescale 1ns/1ps
module tb;
 logic clk=0,run_clock=1,cold=0,hip=0,backend=0,refgood=0;
 wire valid,lost;
 always #5 if(run_clock)clk=~clk;
 platform_domain_health dut(clk,cold,hip,backend,refgood,valid,lost);
 task cycles(input integer n);repeat(n)begin @(posedge clk);#1;end endtask
 task check(input logic want_valid,want_lost);
  if(valid!==want_valid || lost!==want_lost)
   $fatal(1,"health expected %b/%b actual %b/%b",want_valid,want_lost,valid,lost);
 endtask
 task restart;
  cold=0;#2;hip=0;backend=0;refgood=0;cycles(2);
  cold=1;cycles(8);check(1,0);
  hip=1;backend=1;refgood=1;cycles(7);check(1,0);
 endtask
 initial begin
  #1;cold=1;#1;cold=0;
  restart();
  // Independently lose each actual domain; return cannot establish a new epoch.
  for(integer i=0;i<3;i++)begin
   @(negedge clk);#1;
   case(i)0:hip=0;1:backend=0;2:refgood=0;endcase
   #1;check(1,0);
   hip=1;backend=1;refgood=1;
   cycles(8);check(1,1);restart();
  end
  // Loss while destination clock is stopped, including complete pulse recovery.
  @(negedge clk);run_clock=0;#2;backend=0;#2;backend=1;
  #20;check(1,0);run_clock=1;cycles(8);check(1,1);
  restart();
  $display("PLATFORM_DOMAIN_HEALTH_PASS sources=3 stopped_clock=1 cold_recovery=1");
  $finish;
 end
 initial begin #10000;$fatal(1,"testbench failed to reach terminal scenario");end
endmodule
