// One full host identity binds one local descriptor generation per coordinated
// cold-reset lifetime. The local token is not a truncated host epoch.
// Losing context closes admission but retains fetch identity for outstanding
// descriptors. Reusing token 1 after reset requires exclusion of old completions.
module fetch_context_binding(
 input logic kernel_clk,pcie_clk,common_cold_reset_n,
 input logic context_live,
 input logic [127:0] host_session,
 input logic [63:0] host_epoch,
 output logic fetch_valid,
 output wire [31:0] fetch_epoch,
 output logic fault,
 output wire admission_ready
);
 wire [192:0] snapshot;
 wire snapshot_valid;
 logic [191:0] bound_identity;
 dma_custody_status_cdc #(.WIDTH(193)) crossing(
  .src_clk(kernel_clk),.dst_clk(pcie_clk),.common_reset_n(common_cold_reset_n),
  .source_status({context_live,host_session,host_epoch}),
  .status(snapshot),.status_valid(snapshot_valid));
 assign fetch_epoch=fetch_valid ? 32'd1 : 32'd0;
 assign admission_ready=fetch_valid && !fault && common_cold_reset_n;
 always_ff @(posedge pcie_clk or negedge common_cold_reset_n)begin
  if(!common_cold_reset_n)begin fetch_valid<=0;fault<=0;bound_identity<=0;end
  else if(snapshot_valid)begin
   if(!fetch_valid && !fault && snapshot[192])begin
    if(snapshot[191:64]==0 || snapshot[63:0]==0)fault<=1;
    else begin fetch_valid<=1;bound_identity<=snapshot[191:0];end
   end else if(fetch_valid && (!snapshot[192] || snapshot[191:0]!=bound_identity))
    fault<=1;
  end
 end
endmodule
