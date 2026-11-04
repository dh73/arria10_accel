module tb;
 logic pcie_clk=0,clk=0;always #3.5 pcie_clk=~pcie_clk;always #5 clk=~clk;
 logic reset_n=0,s_read=0,s_write=0;
 logic [63:0] s_address=0;logic [31:0] s_writedata=0;wire [31:0] s_readdata;
 wire s_waitrequest,s_readdatavalid,read,write,waitrequest,readdatavalid;
 wire [63:0] address;wire [31:0] writedata,readdata;wire [3:0] byteenable;
 wire pending,fault,mem_write;wire [24:0] mem_address;wire [511:0] mem_data;wire [63:0] mem_mask;
 integer cycles=0,accepted=0;wire mem_wait=cycles%5==0;
 pio_cdc_bridge crossing(.src_clk(pcie_clk),.dst_clk(clk),.common_cold_reset_n(reset_n),
 .s_read,.s_write,.s_address,.s_writedata,.s_byteenable(4'hf),.s_waitrequest,.s_readdatavalid,.s_readdata,
 .m_read(read),.m_write(write),.m_address(address),.m_writedata(writedata),.m_byteenable(byteenable),
 .m_waitrequest(waitrequest),.m_readdatavalid(readdatavalid),.m_readdata(readdata));
 ddr_byte_mailbox mailbox(.clk,.cold_reset_n(reset_n),.context_valid(1'b1),.context_identity(192'h123),
 .write_permit(1'b1),.memory_ready(1'b1),.read,.write,.address(6'(address-1024)),.writedata,.byteenable,
 .waitrequest,.readdatavalid,.readdata,.pending,.fault,
 .m_write(mem_write),.m_address(mem_address),.m_writedata(mem_data),.m_byteenable(mem_mask),.m_waitrequest(mem_wait));
 always @(posedge clk)if(reset_n)begin
  cycles<=cycles+1;
  if(fault)$fatal(1,"mailbox fault");
  if(mem_write&&!mem_wait)begin
   if(mem_address!=64 || mem_mask!==(64'(accepted%15+1)<<(4*(accepted/15))) ||
      mem_data!==({480'b0,(32'ha1b2c3d4^32'(accepted+1))}<<(32*(accepted/15))))
     $fatal(1,"host/CDC/DDR masked payload mismatch index=%0d",accepted);
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
  if(result!=0||accepted!=240||pending||fault)$fatal(1,"host result/custody failure");
  $display("DDR_BYTE_ACLPCI_RTL_PASS commands=240 masks CDC stalled_backend");$finish;
 end
endmodule
