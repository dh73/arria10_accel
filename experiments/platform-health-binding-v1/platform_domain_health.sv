// Validity of the observed reset/clock epoch, not successful memory operation.
// Calibration/ECC/memory-ready remain independent supervisor status inputs.
// Async-low inputs must meet device clear pulse width and reset-routing rules.
// common_cold_reset_n may clear history ONLY after external epoch settlement.
module platform_domain_health(
 input logic kernel_clk,common_cold_reset_n,
 input logic hip_reset_n,backend_reset_n,ref_clock_good,
 output wire health_valid,
 output logic epoch_lost
);
 (* async_reg="true", preserve *) logic [2:0] common_release,domain_release;
 logic armed;
 wire domains_live=common_cold_reset_n && hip_reset_n &&
                   backend_reset_n && ref_clock_good;
 always_ff @(posedge kernel_clk or negedge common_cold_reset_n)
  if(!common_cold_reset_n) common_release<=0;
  else common_release<={common_release[1:0],1'b1};
 // Capture a reset pulse even if the kernel clock has stopped. Recovery of
 // the inputs cannot erase the zero chain before resumed clocks inspect it.
 always_ff @(posedge kernel_clk or negedge domains_live)
  if(!domains_live) domain_release<=0;
  else domain_release<={domain_release[1:0],1'b1};
 always_ff @(posedge kernel_clk or negedge common_release[2])
  if(!common_release[2]) begin armed<=0;epoch_lost<=0;end
  else begin
   if(domain_release[2]) armed<=1;
   if(armed && !domain_release[2]) epoch_lost<=1;
  end
 // This is snapshot validity, NOT admission. Keep failures readable. The shell
 // must feed epoch_lost into the supervisor's sticky fault path; memory-ready,
 // DMA-status validity and reset containment retain their independent gates.
 assign health_valid=common_release[2];
endmodule
