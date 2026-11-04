`timescale 1ns/1ps
module pio_cdc_bridge_tb;
 logic src_clk=0,dst_clk=0,common_cold_reset_n=0;
 logic s_read=0,s_write=0;
 logic [63:0] s_address=0;
 logic [31:0] s_writedata=0;
 logic [3:0] s_byteenable=0;
 wire s_waitrequest,s_readdatavalid;
 wire [31:0] s_readdata;
 wire m_read,m_write;
 wire [63:0] m_address;
 wire [31:0] m_writedata;
 wire [3:0] m_byteenable;
 logic m_waitrequest=1,m_readdatavalid=0;
 logic [31:0] m_readdata=0;
 pio_cdc_bridge dut(.*);
 int src_half=7,dst_half=5;
 initial begin void'($value$plusargs("SRC_HALF=%d",src_half));forever #(src_half)src_clk=~src_clk;end
 initial begin void'($value$plusargs("DST_HALF=%d",dst_half));forever #(dst_half)dst_clk=~dst_clk;end
 int accepted=0,returned=0,cycles=0,pending=0,delay_left=0;
 logic[31:0] memory[0:63];
 logic[31:0] pending_data;
 always @(posedge src_clk) if(s_readdatavalid)returned++;
 always @(negedge dst_clk) begin
  cycles++;
  m_waitrequest=!common_cold_reset_n || cycles%5<2;
  m_readdatavalid=0;
  if(pending) begin
   if(delay_left==0)begin m_readdata=pending_data;m_readdatavalid=1;pending=0;end
   else delay_left--;
  end
 end
 always @(posedge dst_clk) if(common_cold_reset_n && (m_read||m_write) && !m_waitrequest)begin
  if(m_address!==64'(accepted*4) || m_byteenable!==4'hf || m_read!==1'(accepted%2) || m_write!==1'(!(accepted%2)))
   $fatal(1,"CDC command order/fields changed at %0d",accepted);
  if(m_write)begin
   if(m_writedata!==32'(accepted*12345+97))$fatal(1,"CDC write data changed");
   memory[accepted]=m_writedata;
  end else begin
   if(pending)$fatal(1,"multiple pending read");
   pending_data=32'(accepted*177+31);delay_left=accepted%7;pending=1;
  end
  accepted++;
 end
 initial begin
  repeat(4)@(negedge src_clk);common_cold_reset_n=1;
  for(int n=0;n<64;n++)begin
   @(negedge src_clk);s_address=64'(n*4);s_writedata=32'(n*12345+97);s_byteenable=15;
   s_read=1'(n%2);s_write=!s_read;
   do begin @(posedge src_clk);end while(s_waitrequest);
   @(negedge src_clk);s_read=0;s_write=0;s_address='1;s_writedata='1;s_byteenable=0;
   if(n%2)begin
    do begin @(posedge src_clk);#1;end while(!s_readdatavalid);
    if(s_readdata!==32'(n*177+31))$fatal(1,"CDC response mismatch %0d",n);
   end
  end
  wait(!s_waitrequest);repeat(3)@(negedge src_clk);
  if(accepted!=64 || returned!=32)$fatal(1,"CDC conservation %0d/%0d",accepted,returned);
  $display("PIO_CDC_PASS accepted=%0d returned=%0d src_half=%0d dst_half=%0d",accepted,returned,src_half,dst_half);$finish;
 end
endmodule
