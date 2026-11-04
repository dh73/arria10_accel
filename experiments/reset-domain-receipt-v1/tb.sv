module tb;
 logic monitor_clk=0,target_clk=0,run_target=1,configuration_reset_n=0;
 logic request=0,target_reset_n=1;wire observed_reset,fault;
 always #5 monitor_clk=~monitor_clk;
 always #7 if(run_target)target_clk=~target_clk;
 reset_domain_receipt dut(.*);
 task ticks(input integer n);repeat(n)@(negedge monitor_clk);endtask
 task issue;request=1;ticks(1);request=0;endtask
 initial begin
  ticks(3);configuration_reset_n=1;ticks(8);
  issue();ticks(12);if(observed_reset || fault)$fatal(1,"ACK_WITH_RESET_HIGH");
  @(negedge target_clk);run_target=0;target_reset_n=0;
  ticks(12);if(observed_reset)$fatal(1,"ACK_WITHOUT_TARGET_EDGE");
  run_target=1;ticks(15);if(!observed_reset || fault)$fatal(1,"MISSING_FIRST_RECEIPT");
  target_reset_n=1;ticks(8);if(!observed_reset)$fatal(1,"RECEIPT_NOT_HELD");
  issue();if(observed_reset)$fatal(1,"STALE_RECEIPT_REUSED");
  ticks(12);if(observed_reset)$fatal(1,"SECOND_ACK_WITH_RESET_HIGH");
  target_reset_n=0;ticks(15);if(!observed_reset || fault)$fatal(1,"MISSING_SECOND_RECEIPT");
  target_reset_n=1;issue();ticks(2);issue();ticks(4);
  if(!fault || observed_reset)$fatal(1,"OVERLAPPING_REQUEST_NOT_REJECTED");
  target_reset_n=0;ticks(15);if(!fault || observed_reset)$fatal(1,"FAULT_NOT_STICKY");
  $display("RESET_DOMAIN_RECEIPT_PASS stopped_clock stale_receipt two_rounds overlap");$finish;
 end
endmodule
