// Candidate sequencing only: external startup/flush certificates remain unresolved.
// clk is an independent always-on clock. configuration_reset_n is exclusively
// a qualified configuration/power-on reset, NEVER NPOR/PERST/HIP/backend reset.
// All certificate/request inputs are coherent in clk domain. Each certificate
// must describe actual boundary custody, not a timeout, calibration or reset bit.
module physical_reset_quarantine(
 input logic clk,configuration_reset_n,
 // Independent asynchronous-low controls: NPOR, PERST, HIP app reset,
 // EMIF user reset and reference-clock qualification, respectively.
 input logic [4:0] domain_live_n,
 input logic startup_epoch_valid,
 input logic managed_epoch_request,
 // PCIe, DDR and cross-domain transport boundaries, respectively.
 input logic [2:0] boundary_closed_ack,boundary_drained_ack,reset_flush_ack,
 output wire common_cold_reset_n,containment_valid,close_boundaries,
 output wire epoch_reset_request,
 output logic [4:0] fault_history,
 output wire recovery_failed,
 output wire [2:0] state_status
);
 typedef enum logic [2:0] {STARTUP,LIVE,QUARANTINE,RESET_EPOCH,RELEASE_EPOCH,FAILED,FAILED_RELEASE} state_t;
 state_t state;
 (* async_reg="true",preserve *) logic [2:0] health[5];
 wire [4:0] healthy;
 for(genvar i=0;i<5;i++)begin:g_health
  wire async_live=configuration_reset_n && domain_live_n[i];
  always_ff @(posedge clk or negedge async_live)
   if(!async_live)health[i]<=0;
   else health[i]<={health[i][1:0],1'b1};
  assign healthy[i]=health[i][2];
 end
 logic [2:0] closed_low,drained_low,flush_low;
 logic request_low,managed_release;
 logic [4:0] release_armed;
 wire all_live=(&healthy) && (&domain_live_n);
 wire settled=(&boundary_closed_ack) && (&boundary_drained_ack);
 // Raw loss immediately withdraws admission even if clk stops. Synchronized
 // low history then drives sticky quarantine when clk resumes.
 assign containment_valid=configuration_reset_n && state==LIVE && all_live;
 assign common_cold_reset_n=configuration_reset_n &&
      (state==LIVE || state==QUARANTINE || state==RELEASE_EPOCH || state==FAILED_RELEASE);
 assign close_boundaries=!containment_valid;
 assign epoch_reset_request=configuration_reset_n && state==RESET_EPOCH;
 assign recovery_failed=state==FAILED || state==FAILED_RELEASE;
 assign state_status=state;
 always_ff @(posedge clk or negedge configuration_reset_n)begin
  if(!configuration_reset_n)begin
   state<=STARTUP;fault_history<=0;closed_low<=0;drained_low<=0;
   flush_low<=0;request_low<=0;managed_release<=0;release_armed<=0;
  end else begin
   case(state)
    STARTUP:begin
     // This is the explicit external startup-epoch certificate. It asserts
     // all old traffic is absent/contained and cold initialization is safe.
     if(startup_epoch_valid)begin state<=RELEASE_EPOCH;managed_release<=0;end
    end
    RELEASE_EPOCH:begin
     // Health release alone cannot enter this state: startup or fresh managed
     // closure/drain/flush certification must already have occurred.
     // Managed certificates authorize the interval through admission, not
     // merely the single flush-ack edge. Initial startup uses its separate
     // startup certificate and does not require managed acknowledgements.
     release_armed<=release_armed | (healthy & domain_live_n);
     if(managed_release && (!settled || !(&reset_flush_ack) ||
                            |(release_armed & (~healthy | ~domain_live_n))))begin
      state<=FAILED_RELEASE;
      fault_history<=fault_history | (release_armed & (~healthy | ~domain_live_n));
     end else if(all_live)state<=LIVE;
    end
    LIVE:if(!all_live)begin
     fault_history<=fault_history | ~healthy | ~domain_live_n;
     state<=QUARANTINE;closed_low<=0;drained_low<=0;flush_low<=0;request_low<=0;
    end
    QUARANTINE:begin
     fault_history<=fault_history | ~healthy | ~domain_live_n;
     // Reject pre-existing high acknowledgements and stale reset requests.
     closed_low<=closed_low | ~boundary_closed_ack;
     drained_low<=drained_low | ~boundary_drained_ack;
     if(!managed_epoch_request)request_low<=1;
     if(request_low && managed_epoch_request && (&closed_low) &&
        (&drained_low) && settled)begin
      state<=RESET_EPOCH;flush_low<=0;
     end
    end
    RESET_EPOCH:begin
     // The environment must retain these certificates throughout reset.
     // Loss is unrecoverable here; never release on partial/ambiguous flush.
     if(!settled)state<=FAILED;
     else begin
      flush_low<=flush_low | ~reset_flush_ack;
      if((&flush_low) && (&reset_flush_ack))begin
       state<=RELEASE_EPOCH;managed_release<=1;
       release_armed<=healthy & domain_live_n;
      end
     end
    end
    // Release has already occurred: losing its certificate cannot authorize
    // a second custody-clearing reset. Hold isolation and preserve custody.
    FAILED_RELEASE:begin end
    FAILED:begin end // Only qualified configuration reset can leave this state.
    default:state<=FAILED;
   endcase
  end
 end
endmodule
