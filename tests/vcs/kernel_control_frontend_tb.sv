`timescale 1ns/1ps
module kernel_control_frontend_tb;
 localparam logic[63:0] BASE=64'h0000000100000100;
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
 int issued=0;
 kernel_control_frontend #(.MAILBOX_BASE(BASE)) dut(.*);
 always @(posedge kernel_clk)if(common_cold_reset_n && (cra_read||cra_write)&&!cra_waitrequest)begin
  issued++;
  if(!cra_write || cra_read || cra_address!=8 || cra_writedata!==64'h1122334455667788 || cra_byteenable!=8'hff)
   $fatal(1,"frontend command corrupted");
 end
 task automatic put(input logic[63:0] a,input logic[31:0] d);
  @(negedge pcie_clk);address=a;writedata=d;write=1;
  do @(posedge pcie_clk);while(waitrequest);
  @(negedge pcie_clk);write=0;
 endtask
 task automatic get(input logic[63:0] a,output logic[31:0] d);
  @(negedge pcie_clk);address=a;read=1;
  do @(posedge pcie_clk);while(waitrequest);
  @(negedge pcie_clk);read=0;
  do begin @(posedge pcie_clk);#1;end while(!readdatavalid);
  d=readdata;
 endtask
 initial begin
  logic[31:0] value;
  repeat(4)@(negedge pcie_clk);common_cold_reset_n=1;
  // Valid target/data setup followed by rejected aliases of the command slot.
  put(BASE,8);put(BASE+4,32'h55667788);put(BASE+8,32'h11223344);put(BASE+12,255);
  put(64'h110,1);put(BASE+256+16,1);put(BASE-4,1);put(BASE+17,1);
  get(BASE+20,value);
  if(issued!=0 || !invalid_access)$fatal(1,"aliased command executed");
  get(BASE+32,value);if(value!==32'hffffffff)$fatal(1,"upper boundary alias");
  get(64'h118,value);if(value!==32'hffffffff)$fatal(1,"truncated read address");
  get(BASE-4,value);if(value!==32'hffffffff)$fatal(1,"lower boundary alias");
  put(BASE+16,1);
  do get(BASE+20,value);while(value[0]);
  if(value!==2 || issued!=1)$fatal(1,"valid command missing or duplicated");
  // Result accesses have no CRA side effect.
  get(BASE+24,value);get(BASE+28,value);
  if(issued!=1)$fatal(1,"result read issued CRA request");
  $display("KERNEL_CONTROL_FRONTEND_PASS issued=%0d",issued);$finish;
 end
endmodule
