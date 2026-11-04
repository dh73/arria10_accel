module tb;
 logic pcie_clk=0,clk=0;always #3.5 pcie_clk=~pcie_clk;always #5 clk=~clk;
 logic reset_n=0,s_read=0,s_write=0;
 logic [63:0] s_address=0;logic [31:0] s_writedata=0;wire [31:0] s_readdata;
 wire s_waitrequest,s_readdatavalid,read,write,waitrequest,readdatavalid;
 wire [63:0] address;wire [31:0] writedata,readdata;wire [3:0] byteenable;
 wire pending,fault,mem_write,mem_read;logic mem_valid=0;logic [511:0] mem_rdata=0,line_data={64{8'h5a}};integer response_delay=0,reads=0;wire [24:0] mem_address;wire [511:0] mem_data;wire [63:0] mem_mask;
 integer cycles=0,accepted=0;wire mem_wait=cycles%5==0;
 pio_cdc_bridge crossing(.src_clk(pcie_clk),.dst_clk(clk),.common_cold_reset_n(reset_n),
 .s_read,.s_write,.s_address,.s_writedata,.s_byteenable(4'hf),.s_waitrequest,.s_readdatavalid,.s_readdata,
 .m_read(read),.m_write(write),.m_address(address),.m_writedata(writedata),.m_byteenable(byteenable),
 .m_waitrequest(waitrequest),.m_readdatavalid(readdatavalid),.m_readdata(readdata));
 ddr_byte_mailbox_verified mailbox(.clk,.cold_reset_n(reset_n),.context_valid(1'b1),.context_identity(192'h123),
 .write_permit(1'b1),.memory_ready(1'b1),.read,.write,.address(6'(address-1024)),.writedata,.byteenable,
 .waitrequest,.readdatavalid,.readdata,.pending,.fault,
 .m_read(mem_read),.m_readdatavalid(mem_valid),.m_readdataerror(1'b0),.m_readdata(mem_rdata),.m_write(mem_write),.m_address(mem_address),.m_writedata(mem_data),.m_byteenable(mem_mask),.m_waitrequest(mem_wait));
 always @(posedge clk)if(reset_n)begin
  cycles<=cycles+1;
  mem_valid<=0;
  if(response_delay>0)begin
   response_delay<=response_delay-1;
   if(response_delay==1)begin mem_valid<=1;mem_rdata<=line_data;end
  end
  if(mem_read&&!mem_wait)begin
   if(response_delay!=0||mem_address!=64)$fatal(1,"readback ownership/address");
   response_delay<=4;reads<=reads+1;
  end
  if(fault)$fatal(1,"mailbox fault");
  if(mem_write&&!mem_wait)begin
   if(mem_address!=64 || mem_mask!==(64'(accepted%15+1)<<(4*(accepted/15))) ||
      mem_data!==({480'b0,(32'ha1b2c3d4^32'(accepted+1))}<<(32*(accepted/15))))
     $fatal(1,"host/CDC/DDR masked payload mismatch index=%0d",accepted);
   for(integer b=0;b<64;b=b+1)if(mem_mask[b])line_data[b*8+:8]<=mem_data[b*8+:8];
   accepted<=accepted+1;
  end
 end
 export "DPI-C" task byte_get;
 export "DPI-C" task byte_put;
 import "DPI-C" context task byte_host(output int result);
 task byte_put(input longint unsigned a,input int unsigned d);
  @(negedge pcie_clk);s_address=a;s_writedata=d;s_write=1;
  do @(posedge pcie_clk);while(s_waitrequest);
  @(negedge pcie_clk);s_write=0;
 endtask
 task byte_get(input longint unsigned a,output int unsigned d);
  @(negedge pcie_clk);s_address=a;s_read=1;
  do @(posedge pcie_clk);while(s_waitrequest);
  @(negedge pcie_clk);s_read=0;
  wait(s_readdatavalid);#1;d=s_readdata;@(negedge pcie_clk);
 endtask
 initial begin
  int result;repeat(5)@(negedge pcie_clk);reset_n=1;
  byte_host(result);
  if(result!=0||accepted!=240||reads!=240||response_delay!=0||pending||fault)$fatal(1,"host result/custody failure");
  $display("DDR_BYTE_READBACK_HOST_RTL_PASS commands=240 masks CDC stalled_backend");$finish;
 end
endmodule
