module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,snapshot=0,read=0,write=0,waitrequest=0,readdatavalid=0;
 logic [63:0] byteenable=0;
 wire snapshot_valid,snapshot_overflow,snapshot_invalid_command;
 wire [63:0] snapshot_sequence;
 wire [6:0][63:0] snapshot_counts;
 ddr_traffic_counters #(.COUNTER_W(8)) dut(.*);
 task tick;@(posedge clk);#1;@(negedge clk);endtask
 initial begin
  tick();cold_reset_n=1;
  write=1;byteenable=64'h8000000000000001;tick(); // 2 enabled bytes
  waitrequest=1;byteenable='1;repeat(3)tick(); // stalls do not count writes
  waitrequest=0;read=1;write=0;tick();
  read=0;write=1;byteenable='1;readdatavalid=1;tick(); // 64 bytes + response
  write=0;readdatavalid=0;snapshot=1;tick();snapshot=0;
  if(!snapshot_valid||snapshot_sequence!=1||snapshot_overflow||snapshot_invalid_command)
   $fatal(1,"snapshot metadata");
  if(snapshot_counts[0]!=6||snapshot_counts[1]!=1||snapshot_counts[2]!=2||
     snapshot_counts[3]!=66||snapshot_counts[4]!=3||snapshot_counts[5]!=1||snapshot_counts[6]!=6)
   $fatal(1,"accepted/stalled/byte accounting %h",snapshot_counts);
  repeat(4)tick();if(snapshot_counts[0]!=6)$fatal(1,"snapshot changed without request");
  snapshot=1;read=1;tick();snapshot=0;read=0;
  if(snapshot_sequence!=2||snapshot_counts[0]!=11||snapshot_counts[1]!=1)
   $fatal(1,"snapshot failed prefix boundary");
  read=1;write=1;tick();read=0;write=0;
  repeat(256)tick();snapshot=1;tick();snapshot=0;
  if(!snapshot_overflow||!snapshot_invalid_command)$fatal(1,"sticky diagnostic lost");
  cold_reset_n=0;tick();if(snapshot_valid||snapshot_sequence||snapshot_counts||snapshot_overflow||snapshot_invalid_command)
   $fatal(1,"cold reset retained old sample");
  $display("DDR_COUNTERS_PASS accepted stalled byte_mask atomic_snapshot overflow reset");$finish;
 end
endmodule
