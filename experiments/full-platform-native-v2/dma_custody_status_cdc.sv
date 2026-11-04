// Bundled-data request/ack snapshot, never independently synchronized debt bits.
// Source holds data from request toggle through destination acknowledgement.
// Common reset assertion; deassert reset synchronously in each clock domain.
// Physical integration still needs CDC/bundled-data path constraints.
module dma_custody_status_cdc #(parameter int WIDTH=8)(
 input logic src_clk,dst_clk,common_reset_n,
 input logic [WIDTH-1:0] source_status,
 output logic [WIDTH-1:0] status,
 output logic status_valid
);
 logic request,acknowledge;
 logic [WIDTH-1:0] held;
 (* async_reg="true" *) logic [1:0] ack_sync,request_sync,src_release,dst_release;
 always_ff @(posedge src_clk or negedge common_reset_n)begin
  if(!common_reset_n)begin request<=0;held<=0;ack_sync<=0;src_release<=0;end
  else begin
   src_release<={src_release[0],1'b1};ack_sync<={ack_sync[0],acknowledge};
   if(src_release[1] && ack_sync[1]==request)begin held<=source_status;request<=!request;end
  end
 end
 always_ff @(posedge dst_clk or negedge common_reset_n)begin
  if(!common_reset_n)begin acknowledge<=0;request_sync<=0;dst_release<=0;status<=0;status_valid<=0;end
  else begin
   dst_release<={dst_release[0],1'b1};request_sync<={request_sync[0],request};
   if(dst_release[1] && request_sync[1]!=acknowledge)begin
    status<=held;status_valid<=1;acknowledge<=request_sync[1];
   end
  end
 end
endmodule
