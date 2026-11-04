// Receipt of a target-clock edge with local reset asserted. This does not
// certify external traffic closure, drain, or a hard-IP flush.
// Both protocol halves reset ONLY with the common configuration reset.
module reset_domain_receipt(
 input logic monitor_clk,target_clk,configuration_reset_n,
 input logic request,target_reset_n,
 output logic observed_reset,output logic fault
);
 logic request_toggle,ack_toggle,request_seen,pending;
 (* async_reg="true" *) logic [2:0] req_sync,ack_sync,monitor_release,target_release;
 always_ff @(posedge target_clk or negedge configuration_reset_n)begin
  if(!configuration_reset_n)begin req_sync<=0;ack_toggle<=0;target_release<=0;end
  else begin
   target_release<={target_release[1:0],1'b1};
   req_sync<={req_sync[1:0],request_toggle};
   if(target_release[2] && req_sync[2]!=ack_toggle && !target_reset_n)
    ack_toggle<=req_sync[2];
  end
 end
 always_ff @(posedge monitor_clk or negedge configuration_reset_n)begin
  if(!configuration_reset_n)begin
   request_toggle<=0;request_seen<=0;pending<=0;
   observed_reset<=0;fault<=0;ack_sync<=0;monitor_release<=0;
  end else begin
   monitor_release<={monitor_release[1:0],1'b1};
   ack_sync<={ack_sync[1:0],ack_toggle};
   if(monitor_release[2])begin
    request_seen<=request;
    if(request && !request_seen)begin
     observed_reset<=0;
     if(pending || fault)fault<=1;
     else begin request_toggle<=!request_toggle;pending<=1;end
    end else if(pending && ack_sync[2]==request_toggle && !fault)begin
     pending<=0;observed_reset<=1;
    end
   end
   if(fault)observed_reset<=0;
  end
 end
endmodule
