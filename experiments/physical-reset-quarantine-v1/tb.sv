module tb;
 logic startup_clk=0;
 always #5 startup_clk=~startup_clk;
 wire hold_complete;
 logic startup_test_done=0;
 configuration_startup_hold startup_hold(.clk(startup_clk),.hold_complete);
 initial begin
  for(int n=1;n<=41503;n++)begin
   @(posedge startup_clk);#1;
   if(n<41503 && hold_complete)$fatal(1,"startup hold released early cycle=%0d",n);
   if(n==41503 && !hold_complete)$fatal(1,"startup hold failed to release");
  end
  repeat(20)begin @(posedge startup_clk);#1;
   if(!hold_complete)$fatal(1,"startup hold reasserted");
  end
  startup_test_done=1;
 end
 logic clk=0,run_clock=1,configuration_reset_n=0;
 always #5 if(run_clock)clk=~clk;
 logic [4:0] domain_live_n=0;
 logic startup_epoch_valid=0,managed_epoch_request=0;
 logic [2:0] boundary_closed_ack=0,boundary_drained_ack=0,reset_flush_ack=0;
 wire common_cold_reset_n,containment_valid,close_boundaries,epoch_reset_request,recovery_failed;
 wire [4:0] fault_history;
 wire [2:0] state_status;
 physical_reset_quarantine dut(.*);
 task tick(input int n=1);repeat(n)@(negedge clk);endtask
 task boot;
  configuration_reset_n=0;domain_live_n=0;startup_epoch_valid=0;
  managed_epoch_request=0;boundary_closed_ack=0;boundary_drained_ack=0;reset_flush_ack=0;
  tick(2);configuration_reset_n=1;domain_live_n='1;tick(8);
  if(common_cold_reset_n || containment_valid)$fatal(1,"startup certificate bypassed");
  startup_epoch_valid=1;tick();startup_epoch_valid=0;tick(5);
  if(!containment_valid || !common_cold_reset_n)$fatal(1,"startup release failed");
 endtask
 task loss(input int bitno);
  boundary_closed_ack='1;boundary_drained_ack='1;reset_flush_ack='1;managed_epoch_request=1;
  run_clock=0;#2;domain_live_n[bitno]=0;#1;
  if(containment_valid)$fatal(1,"loss did not withdraw admission asynchronously");
  domain_live_n[bitno]=1;#2;run_clock=1;tick(8);
  if(containment_valid || !common_cold_reset_n || !fault_history[bitno])
   $fatal(1,"reset pulse lost or custody reset prematurely bit=%0d",bitno);
 endtask
 task request_reset;
  // stale high certificates must not qualify, even after quiet healthy time.
  boundary_closed_ack='1;boundary_drained_ack='1;reset_flush_ack='1;
  managed_epoch_request=1;tick(8);
  if(epoch_reset_request || !common_cold_reset_n)$fatal(1,"stale certificates accepted");
  managed_epoch_request=0;boundary_closed_ack=0;boundary_drained_ack=0;tick(2);
  managed_epoch_request=1;boundary_closed_ack='1;boundary_drained_ack=3'b011;tick(3);
  if(epoch_reset_request)$fatal(1,"partial drain accepted");
  boundary_drained_ack='1;tick(2);
  if(!epoch_reset_request || common_cold_reset_n)$fatal(1,"managed reset not issued");
  tick(5);if(!epoch_reset_request)$fatal(1,"stale flush accepted");
 endtask
 initial begin
  for(int b=0;b<5;b++)begin boot();loss(b);end
  request_reset();reset_flush_ack=0;tick(2);reset_flush_ack=3'b011;tick(3);
  if(!epoch_reset_request)$fatal(1,"partial flush accepted");
  domain_live_n=0;reset_flush_ack='1;tick(3);
  if(!common_cold_reset_n || containment_valid)$fatal(1,"release health ignored");
  domain_live_n='1;tick(8);
  if(!containment_valid || !fault_history[4])$fatal(1,"managed recovery/history failed");
  loss(1);request_reset();boundary_closed_ack=0;tick(2);
  if(!recovery_failed || common_cold_reset_n || containment_valid)$fatal(1,"closure loss not fatal");
  boundary_closed_ack='1;reset_flush_ack=0;tick(2);reset_flush_ack='1;
  startup_epoch_valid=1;tick(10);
  if(!recovery_failed || common_cold_reset_n)$fatal(1,"failed epoch automatically recovered");
  // Each managed certificate must remain valid throughout release.
  for(int cert=0;cert<3;cert++)begin
   boot();loss(0);request_reset();reset_flush_ack=0;tick(2);
   domain_live_n=0;reset_flush_ack='1;tick(2);
   case(cert)
    0:boundary_closed_ack=0;
    1:boundary_drained_ack=0;
    2:reset_flush_ack=0;
   endcase
   tick(2);domain_live_n='1;tick(8);
   if(!recovery_failed || containment_valid || !common_cold_reset_n)
    $fatal(1,"managed release certificate lost but reopened or reset custody cert=%0d",cert);
   boundary_closed_ack='1;boundary_drained_ack='1;reset_flush_ack='1;tick(5);
   if(!recovery_failed || containment_valid || !common_cold_reset_n)
    $fatal(1,"managed release failure automatically recovered");
  end
  // A domain may start low during intentional reset; after its qualified
  // return, another loss is a new episode invalidating that flush certificate.
  boot();loss(0);request_reset();reset_flush_ack=0;tick(2);
  domain_live_n=0;reset_flush_ack='1;tick(2);
  domain_live_n[0]=1;tick(5); // Other domains still delay overall release.
  run_clock=0;#2;domain_live_n[0]=0;#1;domain_live_n[0]=1;#2;
  run_clock=1;tick(3);domain_live_n='1;tick(8);
  if(!recovery_failed || containment_valid || !common_cold_reset_n || !fault_history[0])
   $fatal(1,"managed release new domain-loss episode reused old certificate");
  wait(startup_test_done);
  $display("PHYSICAL_RESET_QUARANTINE_PASS sources=5 stale_ack=1 managed_recovery=1 closure_loss=1");$finish;
 end
endmodule
