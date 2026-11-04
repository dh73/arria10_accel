module tb;
 logic monitor_clk=0,configuration_reset_n=0;
 logic [2:0] target_clk=0,run_target='1;
 always #5 monitor_clk=~monitor_clk;
 always #7 if(run_target[0])target_clk[0]=~target_clk[0];
 always #11 if(run_target[1])target_clk[1]=~target_clk[1];
 always #13 if(run_target[2])target_clk[2]=~target_clk[2];
 logic [4:0] domain_live_n='1;
 logic startup_epoch_valid=0,managed_epoch_request=0;
 logic [2:0] boundary_closed_ack=0,boundary_drained_ack=0,boundary_flush_ack='1;
 wire common_cold_reset_n,containment_valid,close_boundaries,epoch_reset_request,recovery_failed;
 wire [2:0] target_reset_n={3{common_cold_reset_n}};
 wire [4:0] fault_history;
 wire [2:0] state_status,reset_observed,receipt_fault;
 managed_reset_composition dut(.*);
 task ticks(input int n);repeat(n)@(negedge monitor_clk);endtask
 task enter_reset;
  domain_live_n[0]=0;ticks(2);domain_live_n[0]=1;ticks(5);
  if(containment_valid || !common_cold_reset_n)$fatal(1,"CUSTODY_RESET_BEFORE_DRAIN");
  managed_epoch_request=0;boundary_closed_ack=0;boundary_drained_ack=0;ticks(3);
  boundary_closed_ack='1;boundary_drained_ack='1;managed_epoch_request=1;ticks(3);
  if(!epoch_reset_request || common_cold_reset_n)$fatal(1,"NO_MANAGED_RESET");
 endtask
 initial begin
  ticks(3);configuration_reset_n=1;ticks(8);
  startup_epoch_valid=1;ticks(5);startup_epoch_valid=0;
  if(!containment_valid)$fatal(1,"STARTUP_FAILED");
  @(negedge target_clk[2]);run_target[2]=0;
  enter_reset();ticks(25);
  if(reset_observed[2] || !epoch_reset_request)$fatal(1,"STOPPED_CLOCK_RELEASED");
  boundary_flush_ack=0;ticks(3);boundary_flush_ack='1;ticks(5);
  if(!epoch_reset_request)$fatal(1,"FLUSH_REPLACED_RESET_EDGE");
  run_target[2]=1;ticks(30);
  if(!containment_valid || receipt_fault || recovery_failed)$fatal(1,"RECOVERY_FAILED");
  // A second epoch must reject both the retained receipt and stale flush.
  enter_reset();ticks(30);
  if(!epoch_reset_request || common_cold_reset_n)$fatal(1,"STALE_FLUSH_REUSED");
  boundary_flush_ack=0;ticks(3);boundary_flush_ack=3'b011;ticks(10);
  if(!epoch_reset_request)$fatal(1,"PARTIAL_FLUSH_ACCEPTED");
  boundary_flush_ack='1;ticks(15);
  if(!containment_valid || receipt_fault || recovery_failed)$fatal(1,"SECOND_RECOVERY_FAILED");
  $display("MANAGED_RESET_COMPOSITION_PASS stopped_clock stale_flush two_epochs");$finish;
 end
endmodule
