// Passive single-beat 512-bit DDR observation in the EMIF user-clock domain.
// Snapshot is the complete prefix BEFORE its sampling edge. No handshake output.
// counters: cycles, read beats, write beats, enabled write bytes, stall cycles,
// response beats, active command cycles. Rates require a verified clock frequency.
module ddr_traffic_counters #(parameter int COUNTER_W=64)(
 input logic clk,cold_reset_n,snapshot,
 input logic read,write,waitrequest,readdatavalid,
 input logic [63:0] byteenable,
 output logic snapshot_valid,
 output logic [63:0] snapshot_sequence,
 output logic [6:0][63:0] snapshot_counts,
 output logic snapshot_overflow,snapshot_invalid_command
);
 logic [6:0][COUNTER_W-1:0] counts;
 logic overflow,invalid_command;
 logic [6:0] enabled_bytes;
 logic [6:0][6:0] increment;
 wire rd=read&&!write&&!waitrequest;
 wire wr=write&&!read&&!waitrequest;
 always_comb begin
  enabled_bytes=0;
  for(int i=0;i<64;i++)enabled_bytes=enabled_bytes+7'(byteenable[i]);
  increment='0;
  increment[0]=1;increment[1]=7'(rd);increment[2]=7'(wr);
  increment[3]=wr?enabled_bytes:0;
  increment[4]=7'((read||write)&&waitrequest);
  increment[5]=7'(readdatavalid);increment[6]=7'(read||write);
 end
 always_ff @(posedge clk or negedge cold_reset_n)begin
  if(!cold_reset_n)begin
   counts<='0;overflow<=0;invalid_command<=0;
   snapshot_valid<=0;snapshot_sequence<=0;snapshot_counts<='0;
   snapshot_overflow<=0;snapshot_invalid_command<=0;
  end else begin
   for(int i=0;i<7;i++)begin
    counts[i]<=counts[i]+COUNTER_W'(increment[i]);
    if(({1'b0,counts[i]}+(COUNTER_W+1)'(increment[i]))>((COUNTER_W+1)'(1)<<COUNTER_W)-1)
     overflow<=1;
   end
   if(read&&write)invalid_command<=1;
   if(snapshot)begin
    snapshot_valid<=1;snapshot_sequence<=snapshot_sequence+1'b1;
    for(int i=0;i<7;i++)snapshot_counts[i]<=64'(counts[i]);
    snapshot_overflow<=overflow;snapshot_invalid_command<=invalid_command;
   end
  end
 end
`ifndef SYNTHESIS
 initial if(COUNTER_W<7||COUNTER_W>64)$fatal(1,"counter width outside 7..64");
`endif
endmodule
