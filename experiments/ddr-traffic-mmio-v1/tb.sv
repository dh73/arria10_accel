module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,read=0,write=0;
 logic [6:0] address=0;
 logic [31:0] writedata=0;
 logic [3:0] byteenable=15;
 wire readdatavalid,invalid_access;wire [31:0] readdata;
 logic ddr_read=0,ddr_write=0,ddr_waitrequest=0,ddr_readdatavalid=0;
 logic [63:0] ddr_byteenable=0;
 ddr_traffic_mmio dut(.*);
 task tick;@(posedge clk);#1;@(negedge clk);endtask
 task rd(input int a,output logic[31:0] v);
  address=7'(a);read=1;tick();if(!readdatavalid||invalid_access)$fatal(1,"read rejected %d",a);v=readdata;read=0;
 endtask
 task snap;
  address=0;writedata=32'ha10d0001;write=1;tick();write=0;
  if(invalid_access)$fatal(1,"snapshot refused");
 endtask
 initial begin
  logic[31:0] v,seq,lo,hi;
  tick();cold_reset_n=1;
  rd(0,v);if(v!=32'ha10d0001)$fatal(1,"ABI");
  rd(4,v);if(v!=0)$fatal(1,"unsampled valid");
  ddr_write=1;ddr_byteenable='1;repeat(3)tick();ddr_write=0;
  snap();rd(8,seq);rd(4,v);if(seq!=1||v!=1)$fatal(1,"snapshot flags");
  rd(32,lo);rd(36,hi);if({hi,lo}!=3)$fatal(1,"write beat count");
  rd(40,lo);rd(44,hi);if({hi,lo}!=192)$fatal(1,"write byte count");
  // Ongoing traffic must not mutate the retained snapshot.
  ddr_read=1;repeat(5)tick();ddr_read=0;rd(24,v);if(v!=0)$fatal(1,"live counters leaked");
  snap();rd(8,v);if(v==seq)$fatal(1,"torn interval not detectable");
  rd(24,v);if(v!=5)$fatal(1,"read beat count");
  // Partial command and reserved offset cannot cause a snapshot.
  write=1;address=0;byteenable=1;tick();write=0;byteenable=15;
  if(!invalid_access)$fatal(1,"partial command allowed");
  rd(8,v);if(v!=2)$fatal(1,"invalid write changed sequence");
  read=1;address=72;tick();read=0;
  if(!invalid_access||readdata!=0)$fatal(1,"reserved read allowed");
  cold_reset_n=0;tick();cold_reset_n=1;rd(4,v);if(v!=0)$fatal(1,"reset epoch retained");
  $display("DDR_MMIO_PASS width=64 coherent_snapshot sequence_change partial_reserved reset");$finish;
 end
endmodule
