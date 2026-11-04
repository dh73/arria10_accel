`timescale 1ns/1ps
module shell_bar2_control_tb;
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
 int issued=0;
 shell_bar2_control_candidate #(.BAR2_APERTURE_BITS(15),.SOURCE_ID(256'd1),.BUILD_ID(256'd2),
 .MGMT_SPACE(2),.CRA_SPACE(32'h80000000)) dut(
 .context_valid(1'b1),.health_valid(1'b1),.session(128'd1),.epoch(64'd1),
 .state_status(3'd1),.phase_status(3'd1),.release_ready(1'b1),.fault_latched(1'b0),
 .launch_permit(1'b0),.host_submit_permit(1'b0),.fault_history(16'd0),.fault_pending(16'd0),
 .first_fault_code(16'd0),.first_adapter_code(8'd0),.first_adapter_address(35'd0),
 .first_adapter_address_valid(1'b0),.*);
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
  get(BASE+256,value);if(value!==32'h31444941)$fatal(1,"identity magic");
  get(BASE+284,value);if(value!==1)$fatal(1,"identity context not live");
  get(BASE+288,value);if(value!==1)$fatal(1,"identity source");
  get(BASE+320,value);if(value!==2)$fatal(1,"identity build");
  get(BASE+352,value);if(value!==2)$fatal(1,"identity management space");
  get(BASE+356,value);if(value!==32'h80000000)$fatal(1,"logical CRA space");
  get(BASE+360,value);if(value!==256)$fatal(1,"identity base");
  put(BASE+256,32'hdeadbeef);get(BASE+256,value);
  if(value!==32'h31444941 || issued!=0)$fatal(1,"identity write had side effect");
  // Valid target/data setup followed by rejected aliases of the command slot.
  put(BASE,8);put(BASE+4,32'h55667788);put(BASE+8,32'h11223344);put(BASE+12,255);
  put(BASE+64'h110,1);put(BASE+256+16,1);put(BASE-4,1);put(BASE+17,1);
  get(BASE+20,value);
  if(issued!=0 || !invalid_access)$fatal(1,"aliased command executed");
  get(BASE+32,value);if(value!==32'hffffffff)$fatal(1,"upper boundary alias");
  get(BASE+512,value);if(value!==32'hffffffff)$fatal(1,"upper identity boundary");
  get(BASE-4,value);if(value!==32'hffffffff)$fatal(1,"lower boundary alias");
  put(BASE+16,1);
  do get(BASE+20,value);while(value[0]);
  if(value!==2 || issued!=1)$fatal(1,"valid command missing or duplicated");
  // Result accesses have no CRA side effect.
  get(BASE+24,value);get(BASE+28,value);
  if(issued!=1)$fatal(1,"result read issued CRA request");
  // Another correctly decoded, aligned host BAR base gives the same offset.
  put(BASE+64'h8000+16,1);
  do get(BASE+64'h8000+20,value);while(value[0]);
  if(value!==2 || issued!=2)$fatal(1,"relocated BAR command failed");
  $display("SHELL_BAR2_CONTROL_PASS issued=%0d",issued);$finish;
 end
endmodule
