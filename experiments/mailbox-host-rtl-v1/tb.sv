`timescale 1ns/1ps
module mailbox_host_rtl_tb;
 localparam logic[63:0] BASE=64'h0000000100000000;
 logic pcie_clk=0,kernel_clk=0,common_cold_reset_n=0;
 always #7 pcie_clk=~pcie_clk;
 always #5 kernel_clk=~kernel_clk;
 logic read=0,write=0;
 logic [63:0] address=0;
 logic [31:0] writedata=0;
 logic [3:0] byteenable=15;
 wire waitrequest,readdatavalid,invalid_access,cra_read,cra_write;
 wire [31:0] readdata;
 wire [29:0] cra_address;
 wire [63:0] cra_writedata;
 wire [7:0] cra_byteenable;
 logic cra_waitrequest=0,cra_readdatavalid=0;
 logic [63:0] cra_readdata=0;
 int issued=0, reads=0, starts=0, cycles=0, delay_left=0;
 logic [63:0] storage=64'h1122334455667788,pending_data;
 logic pending=0;
 hip_bar2_kernel_control #(.BAR2_APERTURE_BITS(15)) dut(.*);

 always @(negedge kernel_clk) cra_waitrequest=(cycles%5==0);
 always @(posedge kernel_clk)begin
  cycles++;cra_readdatavalid<=0;
  if(common_cold_reset_n)begin
   if(pending)begin
    if(delay_left==0)begin cra_readdatavalid<=1;cra_readdata<=pending_data;pending=0;end
    else delay_left--;
   end
   if((cra_read||cra_write)&&!cra_waitrequest)begin
    issued++;
    if(cra_read)begin
     if(pending || cra_address!=128)$fatal(1,"bad read ownership/address");
     pending_data=storage;storage=0;reads++;pending=1;delay_left=7;
    end else if(cra_address==128)begin
     for(int b=0;b<8;b++)if(cra_byteenable[b])storage[8*b+:8]=cra_writedata[8*b+:8];
    end else if(cra_address==8 && cra_writedata==1 && cra_byteenable==255)starts++;
    else $fatal(1,"bad write");
   end
  end
 end
 import "DPI-C" context task run_mailbox_host(output int result);
 export "DPI-C" task mailbox_put;
 export "DPI-C" task mailbox_get;
 task mailbox_put(input longint unsigned a,input int unsigned d);
  @(negedge pcie_clk);address=a;writedata=d;write=1;
  do @(posedge pcie_clk);while(waitrequest);
  @(negedge pcie_clk);write=0;
 endtask
 task mailbox_get(input longint unsigned a,output int unsigned d);
  @(negedge pcie_clk);address=a;read=1;
  do @(posedge pcie_clk);while(waitrequest);
  @(negedge pcie_clk);read=0;
  do begin @(posedge pcie_clk);#1;end while(!readdatavalid);
  if($isunknown(readdata))$fatal(1,"unknown PIO response");
  d=readdata;
 endtask
 initial begin
  int result;
  repeat(4)@(negedge pcie_clk);common_cold_reset_n=1;
  run_mailbox_host(result);
  if(result!=0)$fatal(1,"host sequencer failed");
  // Let the ambiguously acknowledged, already accepted command finish once.
  repeat(100)@(negedge kernel_clk);
  if(issued!=4 || reads!=2 || starts!=1 || invalid_access)
   $fatal(1,"bad totals issued=%0d reads=%0d starts=%0d invalid=%b",issued,reads,starts,invalid_access);
  $display("MAILBOX_HOST_RTL_PASS issued=%0d reads=%0d starts=%0d",issued,reads,starts);$finish;
 end
endmodule
