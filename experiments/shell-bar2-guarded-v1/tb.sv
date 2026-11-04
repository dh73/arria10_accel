`timescale 1ns/1ps
module mailbox_guard_tb;
 logic clk=0,cold_reset_n=0,write_permit=0;
 always #5 clk=~clk;
 logic read=0,write=0;
 logic [7:0] address=0;
 logic [31:0] writedata=0;
 logic [3:0] byteenable=15;
 wire waitrequest,readdatavalid,invalid_access,write_pending,cra_read,cra_write;
 wire [31:0] readdata;
 wire [29:0] cra_address;
 wire [63:0] cra_writedata;
 wire [7:0] cra_byteenable;
 logic cra_waitrequest=0,cra_readdatavalid=0;
 logic [63:0] cra_readdata=0;
 integer writes=0,reads=0;
 kernel_cra_mailbox_guarded dut(.*);
 always @(posedge clk)begin
  cra_readdatavalid<=0;
  if(cold_reset_n && !cra_waitrequest)begin
   if(cra_write)begin
    if(cra_address!=8 || cra_writedata!=1 || cra_byteenable!=255)$fatal(1,"bad start");
    writes++;
   end
   if(cra_read)begin reads++;cra_readdata<=64'h123456789abcdef0;cra_readdatavalid<=1;end
  end
 end
 task put(input byte a,input int v);
  @(negedge clk);address=a;writedata=v;write=1;
  @(negedge clk);write=0;
 endtask
 task get(input byte a,output logic [31:0] v);
  @(negedge clk);address=a;read=1;
  @(posedge clk);#1;if(!readdatavalid)$fatal(1,"missing response");v=readdata;
  @(negedge clk);read=0;
 endtask
 initial begin
  logic [31:0] v;
  repeat(3)@(negedge clk);cold_reset_n=1;
  put(0,8);put(4,1);put(8,0);put(12,255);
  put(16,1);get(20,v);
  if(v!==6 || writes!=0 || write_pending)$fatal(1,"denied command stale success");
  write_permit=1;cra_waitrequest=1;put(16,1);
  if(!write_pending || !cra_write)$fatal(1,"accepted command missing");
  write_permit=0;
  repeat(6)begin @(negedge clk);if(!cra_write || !write_pending || cra_address!=8 || cra_writedata!=1)$fatal(1,"lost stalled command");end
  cra_waitrequest=0;get(20,v);
  if(v!==2 || writes!=1 || write_pending)$fatal(1,"reserved start not completed once");
  put(16,1);get(20,v);
  if(v!==6 || writes!=1)$fatal(1,"new command admitted after stop");
  write_permit=1'bx;put(16,1);get(20,v);
  if(v!==6 || writes!=1)$fatal(1,"unknown permission admitted");
  // Read-clear completion remains available while new writes are stopped.
  write_permit=0;put(0,0);put(16,2);
  do get(20,v);while(v[0]);
  if(v!==2 || reads!=1)$fatal(1,"completion read denied or duplicated");
  get(24,v);if(v!==32'h9abcdef0)$fatal(1,"result low");
  get(28,v);if(v!==32'h12345678)$fatal(1,"result high");
  if(reads!=1 || writes!=1 || write_pending)$fatal(1,"bad final custody");
  $display("MAILBOX_GUARD_PASS writes=%0d reads=%0d",writes,reads);$finish;
 end
endmodule
