// Narrow status-transport guard, NOT reset_containment_valid or DMA settlement.
// producer_reset_n must be the actual HIP app_nreset_status. A low pulse must
// meet FPGA async-clear pulse width. Common reset retains its existing meaning:
// only an externally coordinated new epoch may clear the sticky loss history.
// Route combined reset as reset logic; constrain async release and bundled CDC.
module dma_status_reset_guard #(parameter int WIDTH=9)(
 input logic src_clk,dst_clk,common_reset_n,producer_reset_n,
 input logic [WIDTH-1:0] source_status,
 output wire [WIDTH-1:0] status,
 output wire status_valid,
 output logic epoch_lost
);
 wire transport_reset_n=common_reset_n && producer_reset_n;
 wire snapshot_valid;
 (* async_reg="true" *) logic [1:0] producer_health;
 logic armed;
 always_ff @(posedge dst_clk or negedge transport_reset_n)
  if(!transport_reset_n) producer_health<=0;
  else producer_health<={producer_health[0],1'b1};
 // This state is intentionally NOT cleared by an independent producer reset.
 always_ff @(posedge dst_clk or negedge common_reset_n)
  if(!common_reset_n)begin armed<=0;epoch_lost<=0;end
  else begin
   if(producer_health[1])armed<=1;
   if(armed && !producer_health[1])epoch_lost<=1;
  end
 // Reset both transport halves, never a single toggle/ack side. No custody
 // state is reset here. Reinitializing the transport cannot clear epoch_lost.
 dma_custody_status_cdc #(.WIDTH(WIDTH)) transport(
  .src_clk,.dst_clk,.common_reset_n(transport_reset_n),.source_status,
  .status,.status_valid(snapshot_valid));
 assign status_valid=common_reset_n && producer_health[1] && armed &&
                     !epoch_lost && snapshot_valid;
endmodule
