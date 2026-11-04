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
 export "DPI-C" task diag_get;
 export "DPI-C" task diag_flags;
 import "DPI-C" context task diagnostic_host(output int result);
 task diag_flags(input int unsigned flags);
  @(negedge dst_clk);status=flags;
 endtask
 task diag_get(input longint unsigned a,output int unsigned value);
  @(negedge src_clk);while(s_waitrequest)@(negedge src_clk);
  s_address=a-1088;s_read=1;s_byteenable=15;
  @(negedge src_clk);s_read=0;
  wait(s_readdatavalid);value=s_readdata;@(negedge src_clk);
 endtask
 initial begin
  int result;
  repeat(4)@(negedge src_clk);common_cold_reset_n=1;
  diagnostic_host(result);
  if(result!=0 || accepted_requests!=516 || invalid_access)$fatal(1,"host reset diagnostic integration result=%0d reads=%0d",result,accepted_requests);
  $display("RESET_DIAGNOSTICS_HOST_RTL_PASS combinations=256 read_requests=516 no_writes=1");$finish;
 end
endmodule
