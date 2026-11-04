module trial #(parameter DEPTH=8, MDEPTH=8, AW=35)(output logic done=0,output integer elapsed=0);
 logic clk=0;always #5 clk=~clk;
 logic reset_n=0;
 integer sent=0,received=0,cycle=0,issued=0;
 logic kr,kwait,kv,dread,dwrite,dwait,dvalid,derr,drained,fault;
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

 logic [24:0] ma;
 logic mr,mw,mfault,mfault2;
 logic [24:0] mid_address;
 logic mid_read,mid_write;
 logic [1:0] mid_wait,mid_valid,mid_error;
 logic [511:0] mid_data;
 logic [1:0] waits,valids,errors;
 logic [511:0] md;
 wire [511:0] response={16{7'b0,addresses[31]}};
 arria10_dma_ddr_mux #(.READ_DEPTH(MDEPTH)) mux(
 .clk,.common_cold_reset_n(reset_n),.backend_reset_n(reset_n),.dma_lock(1'b0),
 .req_address({25'b0,da}),.req_read({1'b0,dread}),.req_write({1'b0,dwrite}),
 .req_writedata({512'b0,dwd}),.req_byteenable({64'b0,dbe}),
 .req_waitrequest(waits),.rsp_valid(valids),.rsp_error(errors),.rsp_data(md),
 .avm_address(mid_address),.avm_read(mid_read),.avm_write(mid_write),.avm_writedata(),.avm_byteenable(),.avm_burstcount(),
 .avm_waitrequest(mid_wait[0]),.avm_readdatavalid(mid_valid[0]),.avm_readdataerror(mid_error[0]),.avm_readdata(mid_data),.fault(mfault));
 arria10_dma_ddr_mux #(.READ_DEPTH(MDEPTH)) downstream(
 .clk,.common_cold_reset_n(reset_n),.backend_reset_n(reset_n),.dma_lock(1'b0),
 .req_address({25'b0,mid_address}),.req_read({1'b0,mid_read}),.req_write({1'b0,mid_write}),
 .req_writedata(1024'b0),.req_byteenable({64'b0,64'hffffffffffffffff}),
 .req_waitrequest(mid_wait),.rsp_valid(mid_valid),.rsp_error(mid_error),.rsp_data(mid_data),
 .avm_address(ma),.avm_read(mr),.avm_write(mw),.avm_writedata(),.avm_byteenable(),.avm_burstcount(),
 .avm_waitrequest(1'b0),.avm_readdatavalid(validpipe[31]),.avm_readdataerror(1'b0),.avm_readdata(response),.fault(mfault2));
 assign dwait=waits[0];assign dvalid=valids[0];assign derr=errors[0];assign dd=md;

 initial begin repeat(4)@(negedge clk);reset_n=1;end
 always @(posedge clk) if(reset_n && !done) begin
  cycle<=cycle+1;
  if(fault || mfault || mfault2 || dwrite || mw || valids[1])$fatal(1,"unexpected fault/write depth=%0d",DEPTH);
  if(kr && !kwait)sent<=sent+1;
  validpipe<={validpipe[30:0],mr};
  for(integer i=31;i>0;i--)addresses[i]<=addresses[i-1];
  if(mr)begin
   if(ma!==25'(issued))$fatal(1,"issue order");
   addresses[0]<=ma;issued<=issued+1;
  end
  if(kv)begin
   if(kd!=={16{32'(received)}})$fatal(1,"response mismatch depth=%0d received=%0d",DEPTH,received);
   received<=received+1;
  end
  if(received==256 && drained)begin
   if(sent!=256 || issued!=256 || validpipe!=0 || mux.count!=0 || mux.core_count!=0 || downstream.count!=0 || downstream.core_count!=0)$fatal(1,"incomplete drain");
   elapsed<=cycle;done<=1;
  end
 end
endmodule
module tb;
 wire a,b,c,d,e,f;
 wire [31:0] base35,adapter35,both35,base41,adapter41,both41;
 trial #(.DEPTH(8),.MDEPTH(8)) base_35(a,base35);
 trial #(.DEPTH(64),.MDEPTH(8)) adapter_35(b,adapter35);
 trial #(.DEPTH(64),.MDEPTH(64)) both_35(c,both35);
 trial #(.DEPTH(8),.MDEPTH(8),.AW(41)) base_41(d,base41);
 trial #(.DEPTH(64),.MDEPTH(8),.AW(41)) adapter_41(e,adapter41);
 trial #(.DEPTH(64),.MDEPTH(64),.AW(41)) both_41(f,both41);
 initial begin
  wait(a && b && c && d && e && f);
  if(base35!=base41 || adapter35!=adapter41 || both35!=both41)$fatal(1,"width mismatch");
  if(both35>=adapter35 || both35>=base35 || both35>300)$fatal(1,"shared credit throughput regression");
  $display("CASCADED_READ_THROUGHPUT_PASS widths=35,41 latency=32 words=256 credits8_8=%0d credits64_8=%0d credits64_64=%0d",base35,adapter35,both35);
  $finish;
 end
endmodule
