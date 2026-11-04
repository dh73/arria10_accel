`timescale 1ns/1ps
module kernel_cra_mailbox_tb;
 logic clk=0,cold_reset_n=0,read=0,write=0;
 logic [7:0] address=0;
 logic [31:0] writedata=0;
 logic [3:0] byteenable=15;
 wire waitrequest,readdatavalid,invalid_access,cra_read,cra_write;
 wire [31:0] readdata;
 wire [29:0] cra_address;
 wire [63:0] cra_writedata;
 wire [7:0] cra_byteenable;
 logic cra_waitrequest=1,cra_readdatavalid=0;
 logic [63:0] cra_readdata=0;
 integer writes=0,reads=0;
 logic [63:0] last_data;
 logic [7:0] last_mask;
 kernel_cra_mailbox dut(.*);
 always #5 clk=~clk;
 always @(posedge clk) if(cold_reset_n && !cra_waitrequest) begin
  if(cra_write) begin writes++;last_data=cra_writedata;last_mask=cra_byteenable;end
  if(cra_read) reads++;
 end
 task automatic put(input logic[7:0] a,input logic[31:0] d);
  @(negedge clk);address=a;writedata=d;write=1;
  @(negedge clk);write=0;
 endtask
 task automatic get(input logic[7:0] a,output logic[31:0] d);
  @(negedge clk);address=a;read=1;
  @(posedge clk);#1;if(!readdatavalid)$fatal(1,"missing PIO response");d=readdata;
  @(negedge clk);read=0;
 endtask
 task automatic expect_status(input logic[31:0] expected);
  logic[31:0] d;get('h14,d);if(d!==expected)$fatal(1,"status %h expected %h",d,expected);
 endtask
 initial begin
  logic[31:0] lo,hi;
  repeat(3) @(negedge clk);cold_reset_n=1;
  put(0,8);put(4,32'h89abcdef);put(8,32'h01234567);put(12,8'hf3);put(16,1);
  expect_status(1);
  // Mutating staging or repeating command while stalled cannot alter custody.
  put(4,0);put(16,1);
  if(!invalid_access || !cra_write || cra_address!=8 || cra_writedata!==64'h0123456789abcdef || cra_byteenable!=8'hf3)
   $fatal(1,"stalled command changed");
  @(negedge clk);cra_waitrequest=0;
  repeat(3) @(negedge clk);expect_status(2);
  if(writes!=1 || last_data!==64'h0123456789abcdef || last_mask!=8'hf3)$fatal(1,"atomic write mismatch");
  // Delayed destructive read: one CRA acceptance, any number of PIO reads.
  put(0,48);put(16,2);
  wait(reads==1);@(negedge clk);expect_status(1);
  repeat(4) @(negedge clk);
  if(reads!=1 || cra_read)$fatal(1,"repeated destructive read");
  cra_readdata=64'h76543210fedcba98;cra_readdatavalid=1;
  @(negedge clk);cra_readdatavalid=0;expect_status(2);
  repeat(3) begin
   get(28,hi);get(24,lo);
   if({hi,lo}!==64'h76543210fedcba98 || reads!=1)$fatal(1,"captured result changed");
  end
  // Same-cycle response must not be dropped or cause another request.
  @(negedge clk);cra_readdata=64'ha55a112233445566;cra_readdatavalid=1;
  put(16,2);repeat(3) @(negedge clk);cra_readdatavalid=0;
  expect_status(2);get(24,lo);get(28,hi);
  if(reads!=2 || {hi,lo}!==64'ha55a112233445566)$fatal(1,"immediate response lost");
  put(0,512);put(16,1);expect_status(6);
  put(0,3);put(16,2);expect_status(6);
  if(reads!=2 || writes!=1)$fatal(1,"invalid address reached CRA");
  // A simultaneous PIO read/write is rejected without triggering a start.
  @(negedge clk);address=16;writedata=1;read=1;write=1;
  @(posedge clk);#1;if(readdata!==32'hffffffff)$fatal(1,"malformed request accepted");
  @(negedge clk);read=0;write=0;
  if(reads!=2 || writes!=1)$fatal(1,"malformed request reached CRA");
  // Common reset cancels both domains, not a unilateral transaction-recovery claim.
  cold_reset_n=0;#1;if(cra_read || cra_write || !waitrequest)$fatal(1,"reset gate");
  $display("KERNEL_CRA_MAILBOX_PASS writes=%0d reads=%0d",writes,reads);$finish;
 end
endmodule
