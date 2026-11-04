`timescale 1ns/1ps
module tb;
 logic src_clk=0,dst_clk=0,common_cold_reset_n=0;
 always #5 src_clk=~src_clk;always #7 dst_clk=~dst_clk;
 logic s_read=0,s_write=0;logic [63:0] s_address=0;
 logic [31:0] s_writedata=0;logic [3:0] s_byteenable=15;
 wire s_waitrequest,s_readdatavalid;wire [31:0] s_readdata;
 integer accepted_requests=0;
 always @(posedge src_clk)if(common_cold_reset_n && (s_read||s_write) && !s_waitrequest)accepted_requests++;
 wire m_read,m_write;wire [63:0] m_address;wire [31:0] m_writedata;
 wire [3:0] m_byteenable;wire m_waitrequest,m_readdatavalid;wire [31:0] m_readdata;
 logic [7:0] status=0;wire invalid_access;
 pio_cdc_bridge crossing(.*);
 platform_reset_diagnostics diagnostics(.clk(dst_clk),.cold_reset_n(common_cold_reset_n),
 .read(m_read),.write(m_write),.address(m_address[2:0]),.byteenable(m_byteenable),.status,
 .waitrequest(m_waitrequest),.readdatavalid(m_readdatavalid),.readdata(m_readdata),.invalid_access);
 task get(input [2:0] address,input [3:0] mask,input [31:0] expected);
  @(negedge src_clk);while(s_waitrequest)@(negedge src_clk);s_address=address;s_byteenable=mask;s_read=1;
  @(negedge src_clk);s_read=0;wait(s_readdatavalid);#1;
  assert(s_readdata===expected)else $fatal(1,"diagnostic address=%0d actual=%h expected=%h",address,s_readdata,expected);
  @(negedge src_clk);
 endtask
 initial begin
  repeat(4)@(negedge src_clk);common_cold_reset_n=1;
  get(0,15,32'h52534401);
  for(integer flags=0;flags<256;flags++)begin
   @(negedge dst_clk);status=flags;get(4,15,flags);
  end
  // Invalid health snapshot and lost DMA epoch remain observable.
  @(negedge dst_clk);status=8'h08;get(4,15,8'h08);
  @(negedge src_clk);while(s_waitrequest)@(negedge src_clk);s_write=1;s_address=4;s_writedata=0;
  @(negedge src_clk);s_write=0;wait(!s_waitrequest);get(4,15,8'h08);
  assert(invalid_access)else $fatal(1,"write not rejected");
  get(2,15,32'hffffffff);get(4,1,32'hffffffff);get(0,15,32'h52534401);
  assert(status==8'h08)else $fatal(1,"diagnostic write changed state");
  assert(accepted_requests==263)else $fatal(1,"lost or duplicate source command count=%0d",accepted_requests);
  $display("PLATFORM_RESET_DIAGNOSTICS_PASS snapshots=256 CDC readonly=1");$finish;
 end
endmodule
