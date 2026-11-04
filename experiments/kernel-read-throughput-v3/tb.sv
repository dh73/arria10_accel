module trial #(parameter DEPTH=8, AW=35)(output logic done=0,output integer elapsed=0);
 logic clk=0;always #5 clk=~clk;
 logic reset_n=0;
 integer sent=0,received=0,cycle=0,issued=0;
 logic kr,kwait,kv,dread,dwrite,dwait=0,dvalid,derr=0,drained,fault;
 logic [AW-1:0] ka;
 logic [511:0] kd,dd,dwd;
 logic [24:0] da;
 logic [63:0] dbe;
 logic db;
 logic [31:0] validpipe='0;
 logic [24:0] addresses[0:31];
 assign kr=reset_n && sent<256;
 assign ka=AW'(sent)*64;
 kernel_ddr_address_width_adapter #(.DATA_W(512),.ADDR_W(AW),.READ_DEPTH(DEPTH)) dut(
 .clk,.cold_reset_n(reset_n),.memory_ready(reset_n),.backend_init_failed(1'b0),
 .backend_ecc_interrupt(1'b0),.quiesce_req(1'b0),.k_read(kr),.k_write(1'b0),
 .k_address(ka),.k_writedata(512'b0),.k_byteenable(64'hffffffffffffffff),
 .k_burstcount(1'b1),.k_waitrequest(kwait),.k_readdata(kd),.k_readdatavalid(kv),.k_writeack(),
 .d_address(da),.d_read(dread),.d_write(dwrite),.d_writedata(dwd),.d_byteenable(dbe),
 .d_burstcount(db),.d_waitrequest(dwait),.d_readdata(dd),.d_readdatavalid(dvalid),.d_readdataerror(derr),
 .fault,.fault_code(),.fault_address(),.fault_address_valid(),.quiescing(),.drained);
 assign dvalid=validpipe[31];
 assign dd={16{7'b0,addresses[31]}};
 initial begin repeat(4)@(negedge clk);reset_n=1;end
 always @(posedge clk) if(reset_n && !done) begin
  cycle<=cycle+1;
  if(fault || dwrite)$fatal(1,"unexpected fault/write depth=%0d",DEPTH);
  if(kr && !kwait)sent<=sent+1;
  validpipe<={validpipe[30:0],dread && !dwait};
  for(integer i=31;i>0;i--)addresses[i]<=addresses[i-1];
  if(dread && !dwait)begin
   if(da!==25'(issued))$fatal(1,"issue order");
   addresses[0]<=da;issued<=issued+1;
  end
  if(kv)begin
   if(kd!=={16{32'(received)}})$fatal(1,"response mismatch depth=%0d received=%0d",DEPTH,received);
   received<=received+1;
  end
  if(received==256 && drained)begin
   if(sent!=256 || issued!=256 || validpipe!=0)$fatal(1,"incomplete drain");
   elapsed<=cycle;done<=1;
  end
 end
endmodule
module tb;
 wire a,b,c,d;wire [31:0] slow,fast,slow41,fast41;
 trial #(.DEPTH(8)) depth8_case(a,slow);
 trial #(.DEPTH(64)) depth64_case(b,fast);
 trial #(.DEPTH(8),.AW(41)) depth8_41(c,slow41);
 trial #(.DEPTH(64),.AW(41)) depth64_41(d,fast41);
 initial begin
  wait(a && b && c && d);
  if(slow41!=slow || fast41!=fast)$fatal(1,"address width throughput mismatch");
  if(fast>=slow || fast>300)$fatal(1,"read throughput regression small=%0d large=%0d",slow,fast);
  $display("READ_THROUGHPUT_PASS address_widths=35,41 latency=32 words=256 depth8_cycles=%0d depth64_cycles=%0d",slow,fast);
  $finish;
 end
endmodule
