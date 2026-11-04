module tb;
 logic clk=0,refclk=0,run_ref=1;
 always #10 clk=~clk;
 always #3.333 if(run_ref)refclk=~refclk;
 wire hold_complete,good,fault,reset_n;
 configuration_startup_hold hold(.clk,.hold_complete);
 reference_clock_monitor #(.DIV_LOG2(6),.MIN_TICKS(9),.MAX_TICKS(13),.GOOD_INTERVALS(3)) monitor(
 .ref_clk(refclk),.monitor_clk(clk),.reset_n(hold_complete),.qualified(good),.fault);
 c126_reset_release #(.ALLOW_RELEASE(1'b1),.HOLD_REF_CYCLES(16)) release_ddr(
 .ref_clk(refclk),.external_reset_n(hold_complete),.ref_clock_good(good),.global_reset_n(reset_n));
 initial begin
  for(integer i=1;i<=41502;i++)begin
   @(negedge clk);
   if(hold_complete!==0 || reset_n!==0)$fatal(1,"EARLY_BOOT_RELEASE cycle=%0d",i);
  end
  @(negedge clk);if(hold_complete!==1)$fatal(1,"MISSING_BOOT_HOLD_COMPLETION");
  repeat(100)@(negedge clk);
  if(good!==1 || reset_n!==1 || fault!==0)$fatal(1,"DDR_STARTUP_NOT_RELEASED");
  run_ref=0;
  repeat(30)@(negedge clk);
  if(fault!==1 || good!==0 || reset_n!==0)$fatal(1,"CLOCK_LOSS_NOT_CONTAINED");
  run_ref=1;
  repeat(100)@(negedge clk);
  if(hold_complete!==1 || fault!==1 || reset_n!==0)$fatal(1,"UNAUTHORIZED_CLOCK_RETURN_RECOVERY");
  $display("PHYSICAL_STARTUP_COMPOSITION_PASS hold=41503 loss_latched no_runtime_rearm");$finish;
 end
endmodule
