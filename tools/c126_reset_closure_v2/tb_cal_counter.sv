// Focused VCS fixture for the unmodified generated soft cal_counter sources.
// Compile WITHOUT ALTERA_EMIF_ENABLE_ISSP and __ALTERA_STD__METASTABLE_SIM.
// This checks deterministic RTL sampling, not analog metastability or hard IP.
module tb_cal_counter;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk = 1'b0;
  logic global_reset_n = 1'b1;
  logic cal_in_progress = 1'b0;
  logic [2:0] reset_samples = 'x;
  logic [2:0] cal_samples = 'x;
  int checked_edges = 0;
  int reset_sampled_low = 0;
  int reset_sampled_high = 0;

  always #5ns clk = ~clk;

  altera_emif_arch_nf_cal_counter #(.IS_HPS(0)) dut (
    .pll_ref_clk_int(clk),
    .global_reset_n_int(global_reset_n),
    .afi_cal_in_progress(cal_in_progress)
  );

  // The default nocut depth is THREE. Its reset_n input is tied HIGH by
  // cal_counter, so global_reset_n is data at din_s1, not asynchronous clear.
  // Explicit X initialization models the absence of an initialization reset.
  always @(posedge clk) begin
    reset_samples = {reset_samples[1:0], global_reset_n};
    cal_samples = {cal_samples[1:0], cal_in_progress};
    #1ps; // observe nonblocking assignments from the unmodified vendor RTL
    if ({dut.non_hps.inst_sync_reset_n.dreg,
         dut.non_hps.inst_sync_reset_n.din_s1} !== reset_samples)
      $fatal(1, "reset sample pipeline mismatch at edge %0d", checked_edges);
    if (dut.non_hps.reset_n_sync !== reset_samples[2])
      $fatal(1, "reset synchronizer output mismatch");
    if ({dut.non_hps.inst_sync_cal_in_progress.dreg,
         dut.non_hps.inst_sync_cal_in_progress.din_s1} !== cal_samples)
      $fatal(1, "calibration sample pipeline mismatch");
    if (dut.non_hps.cal_in_progress_sync !== cal_samples[2])
      $fatal(1, "calibration synchronizer output mismatch");
    if (global_reset_n) reset_sampled_high++;
    else reset_sampled_low++;
    checked_edges++;
  end

  initial begin
    // Start deasserted: do not create a fictitious asynchronous initialization.
    repeat (6) @(negedge clk);
    #2ns global_reset_n = 1'b0;
    #1ns;
    if (dut.non_hps.reset_n_sync !== 1'b1)
      $fatal(1, "data assertion incorrectly acted as asynchronous reset");
    repeat (4) @(negedge clk);
    if (dut.non_hps.reset_n_sync !== 1'b0)
      $fatal(1, "held-low reset data was not sampled through all stages");
    #2ns global_reset_n = 1'b1;
    #1ns;
    if (dut.non_hps.reset_n_sync !== 1'b0)
      $fatal(1, "data deassertion bypassed the sample pipeline");
    repeat (5) @(negedge clk);
    #2ns cal_in_progress = 1'b1;
    repeat (7) @(negedge clk);
    #2ns cal_in_progress = 1'b0;
    repeat (6) @(negedge clk);
    if (dut.done !== 1'b1 || $isunknown(dut.clk_counter) || dut.clk_counter == 0)
      $fatal(1, "cal_counter did not complete a sampled calibration interval");
    // This pulse misses every rising edge and therefore must be ignored.
    #1ns global_reset_n = 1'b0;
    #1ns global_reset_n = 1'b1;
    repeat (4) @(negedge clk);
    if (dut.non_hps.reset_n_sync !== 1'b1 || dut.done !== 1'b1)
      $fatal(1, "unsampled pulse incorrectly changed state");
    #2ns global_reset_n = 1'b0;
    repeat (5) @(negedge clk);
    if (dut.done !== 1'b0)
      $fatal(1, "sampled reset did not return cal_counter to INIT");
    if (checked_edges < 30 || reset_sampled_low < 6 || reset_sampled_high < 20)
      $fatal(1, "fixture did not exercise both sampled values");
    $display("C126_SOFT_CAL_COUNTER_RTL_PASS edges=%0d", checked_edges);
    $finish;
  end
endmodule
