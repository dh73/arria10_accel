// Certificates and requests are coherent in monitor_clk. Boundary certificates
// must be produced by real isolation/drain/flush logic, independently of reset.
module managed_reset_composition(
 input logic monitor_clk,configuration_reset_n,
 input logic [2:0] target_clk,target_reset_n,
 input logic [4:0] domain_live_n,
 input logic startup_epoch_valid,managed_epoch_request,
 input logic [2:0] boundary_closed_ack,boundary_drained_ack,boundary_flush_ack,
 output wire common_cold_reset_n,containment_valid,close_boundaries,
 output wire epoch_reset_request,recovery_failed,
 output wire [4:0] fault_history,
 output wire [2:0] state_status,
 output wire [2:0] reset_observed,receipt_fault
);
 logic epoch_previous;
 logic [2:0] flush_low_seen;
 always_ff @(posedge monitor_clk or negedge configuration_reset_n)begin
  if(!configuration_reset_n)begin epoch_previous<=0;flush_low_seen<=0;end
  else begin
   epoch_previous<=epoch_reset_request;
   if(epoch_reset_request && !epoch_previous)flush_low_seen<=0;
   else if(epoch_reset_request)flush_low_seen<=flush_low_seen | ~boundary_flush_ack;
  end
 end
 for(genvar n=0;n<3;n++)begin:g_receipt
  reset_domain_receipt receipt(
   .monitor_clk,.target_clk(target_clk[n]),.configuration_reset_n,
   .request(epoch_reset_request),.target_reset_n(target_reset_n[n]),
   .observed_reset(reset_observed[n]),.fault(receipt_fault[n]));
 end
 wire [2:0] certified_flush=flush_low_seen & boundary_flush_ack & reset_observed & ~receipt_fault;
 physical_reset_quarantine sequence_control(
  .clk(monitor_clk),.configuration_reset_n,.domain_live_n,
  .startup_epoch_valid,.managed_epoch_request,
  .boundary_closed_ack,.boundary_drained_ack,.reset_flush_ack(certified_flush),
  .common_cold_reset_n,.containment_valid,.close_boundaries,.epoch_reset_request,
  .fault_history,.recovery_failed,.state_status);
endmodule
