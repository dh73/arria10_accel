`timescale 1ns/1ps
module tb;
 logic src_clk=0,dst_clk=0,run_dst=1,common_reset_n=0,producer_reset_n=0;
 logic [8:0] source_status=9'h101;
 wire [8:0] status;
 wire status_valid,epoch_lost;
 always #3 src_clk=~src_clk;
 always #5 if(run_dst)dst_clk=~dst_clk;
 dma_status_reset_guard dut(.*);
 task ticks(input integer n);repeat(n)@(negedge dst_clk);endtask
 task require_valid;
  ticks(30);
  if(!status_valid || status!==source_status || epoch_lost)$fatal(1,"fresh snapshot absent");
 endtask
 initial begin
  ticks(3);common_reset_n=1;
  ticks(10);if(status_valid)$fatal(1,"producer reset allowed validity");
  producer_reset_n=1;require_valid();
  // Destination stopped; a reset pulse shorter than either clock period must
  // immediately revoke the previously valid tuple and survive producer restart.
  run_dst=0;#1;producer_reset_n=0;#0.2;
  if(status_valid)$fatal(1,"stale valid during reset with stopped clock");
  source_status=9'h13f;producer_reset_n=1;#20;
  if(status_valid)$fatal(1,"stale valid after pulse with stopped clock");
  run_dst=1;ticks(30);
  if(status_valid || !epoch_lost)$fatal(1,"reset zeros/restart restored certificate");
  // Only common cold reset releases retained epoch loss.
  common_reset_n=0;ticks(3);
  if(epoch_lost || status_valid)$fatal(1,"common reset semantics");
  common_reset_n=1;require_valid();
  // Pulse entirely between destination edges with both clocks running.
  #1;producer_reset_n=0;#0.2;producer_reset_n=1;
  if(status_valid)$fatal(1,"short pulse failed immediate invalidation");
  ticks(30);
  if(status_valid || !epoch_lost)$fatal(1,"short pulse history lost");
  $display("DMA_STATUS_RESET_GUARD_PASS");$finish;
 end
endmodule
