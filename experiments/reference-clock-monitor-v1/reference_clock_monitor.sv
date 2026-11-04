// Digital cadence monitor. The independent monitor clock must remain running.
// This does not measure jitter, voltage, clock quality or asynchronous MTBF.
// Bounds include divider ratio, oscillator tolerances and synchronizer latency.
// A fault after qualification remains latched until external reset; clock return
// alone must not re-admit work whose memory or transaction state was lost.
module reference_clock_monitor #(
 parameter int DIV_LOG2=0, MIN_TICKS=0, MAX_TICKS=0, GOOD_INTERVALS=0
)(input logic ref_clk, monitor_clk, reset_n,
 output logic qualified, fault);
 localparam int DW=DIV_LOG2>0?DIV_LOG2:1;
 localparam int TW=MAX_TICKS>0?$clog2(MAX_TICKS+2):1;
 localparam int GW=GOOD_INTERVALS>0?$clog2(GOOD_INTERVALS+1):1;
 generate if(DIV_LOG2>=2 && MIN_TICKS>=2 && MAX_TICKS>MIN_TICKS && GOOD_INTERVALS>=2) begin : g_valid
 // Only these chains receive raw asynchronous reset. Counter and detector
 // release is synchronous to its own running clock; assertion stays asynchronous.
 (* async_reg="true", preserve *) logic [2:0] ref_release, monitor_release;
 always_ff @(posedge ref_clk or negedge reset_n)
  if(!reset_n) ref_release<='0;
  else ref_release<={ref_release[1:0],1'b1};
 always_ff @(posedge monitor_clk or negedge reset_n)
  if(!reset_n) monitor_release<='0;
  else monitor_release<={monitor_release[1:0],1'b1};
 logic [DW-1:0] divider;
 (* async_reg="true", preserve *) logic [2:0] heartbeat_sync;
 logic previous, seen;
 logic [TW-1:0] age;
 logic [GW-1:0] good;
 wire edge_seen=heartbeat_sync[2]!=previous;
 // synthesis translate_off
 initial if(DIV_LOG2<2 || MIN_TICKS<2 || MAX_TICKS<=MIN_TICKS || GOOD_INTERVALS<2)
  $fatal(1,"CLOCK_MONITOR_CONFIGURATION_REQUIRED");
 // synthesis translate_on
 always_ff @(posedge ref_clk or negedge ref_release[2])
  if(!ref_release[2]) divider<='0;else divider<=divider+1'b1;
 always_ff @(posedge monitor_clk or negedge monitor_release[2])
  if(!monitor_release[2]) heartbeat_sync<='0;
  else heartbeat_sync<={heartbeat_sync[1:0],divider[DW-1]};
 always_ff @(posedge monitor_clk or negedge monitor_release[2]) begin
  if(!monitor_release[2]) begin
   qualified<=0;fault<=0;previous<=0;seen<=0;age<=0;good<=0;
  end else begin
   previous<=heartbeat_sync[2];
   if(!fault) begin
    if(age<MAX_TICKS+1) age<=age+1'b1;
    if(edge_seen) begin
     seen<=1;age<=0;
     if(seen && age+1>=MIN_TICKS && age+1<=MAX_TICKS) begin
      if(good<GOOD_INTERVALS) good<=good+1'b1;
      if(good==GOOD_INTERVALS-1) qualified<=1;
     end else begin
      good<=0;
      if(qualified) begin qualified<=0;fault<=1;end
     end
    end else if(age>=MAX_TICKS) begin
     seen<=0;good<=0;
     if(qualified) begin qualified<=0;fault<=1;end
    end
   end
  end
 end
 end else begin : g_invalid
  assign qualified=1'b0;
  assign fault=1'b1;
 end endgenerate
endmodule
