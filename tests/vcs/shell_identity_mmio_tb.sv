`timescale 1ns/1ps
module shell_identity_mmio_tb;
 logic clk=0,cold_reset_n=0,read=0,write=0;
 logic [63:0] address=0;
 logic [3:0] byteenable=15;
 wire waitrequest,readdatavalid,invalid_access;
 wire [31:0] readdata;
 localparam logic [63:0] BASE=64'h100001000;
 shell_identity_mmio #(.SOURCE_ID(256'h12345678),.BUILD_ID(256'habcdef01),
 .MGMT_SPACE(2),.CRA_SPACE(0),.MGMT_BASE(BASE),.CRA_BASE(0)) dut (
 .clk,.cold_reset_n,.read,.write,.address,.byteenable,.waitrequest,.readdatavalid,.readdata,.invalid_access,
 .context_valid(1'b1),.session(128'd7),.epoch(64'd1),.health_valid(1'b1),
 .state_status(3'd1),.phase_status(3'd1),.release_ready(1'b0),.fault_latched(1'b0),
 .launch_permit(1'b0),.host_submit_permit(1'b0),.fault_history(16'd0),.fault_pending(16'd0),
 .first_fault_code(16'd0),.first_adapter_code(8'd0),.first_adapter_address(35'd0),
 .first_adapter_address_valid(1'b0));
 task tick; #5;clk=1;#1;clk=0;#4;endtask
 task check(input logic [63:0] a,input logic [31:0] expected);
  address=a;read=1;#1;if(waitrequest) $fatal(1,"unexpected stall");tick();
  if(!readdatavalid || readdata!==expected) $fatal(1,"read %h got %h expected %h",a,readdata,expected);
 endtask
 initial begin
  tick();if(!waitrequest || readdatavalid) $fatal(1,"reset gate");
  cold_reset_n=1;tick();tick();
  check(BASE,32'h31444941);check(BASE+4,32'h10000);check(BASE+12,256);
  check(BASE+32,32'h12345678);check(BASE+64,32'habcdef01);
  check(BASE+104,32'h1000);check(BASE+108,1);
  if(invalid_access) $fatal(1,"valid reads marked invalid");
  check(64'h1000,32'hffffffff); // same low bits must not alias
  check(BASE-4,32'hffffffff);check(BASE+256,32'hffffffff);check(BASE+1,32'hffffffff);
  byteenable=3;check(BASE,32'hffffffff);byteenable=15;
  write=1;check(BASE,32'hffffffff);read=0;tick();
  if(readdatavalid) $fatal(1,"write generated read response");
  write=0;check(BASE,32'h31444941);check(BASE+32,32'h12345678);
  if(!invalid_access) $fatal(1,"missing invalid-access latch");
  read=0;tick();if(readdatavalid) $fatal(1,"duplicate response");
  cold_reset_n=0;tick();if(invalid_access || readdatavalid) $fatal(1,"reset failed");
  $display("SHELL_IDENTITY_MMIO_PASS");$finish;
 end
endmodule
