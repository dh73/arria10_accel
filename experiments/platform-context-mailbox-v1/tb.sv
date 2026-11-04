module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,read=0,write=0;
 logic [5:0] address=0;logic [31:0] writedata=0;logic [3:0] byteenable=15;
 wire readdatavalid,invalid_access,context_valid,fault;wire [31:0] readdata;
 wire [63:0] epoch;wire [127:0] session;
 platform_context_mailbox dut(.*);
 task reset;
  @(negedge clk);cold_reset_n=0;write=0;read=0;
  repeat(2)@(negedge clk);cold_reset_n=1;
 endtask
 task put(input logic [5:0] a,input logic [31:0] v,input logic [3:0] mask=15);
  @(negedge clk);write=1;address=a;writedata=v;byteenable=mask;
  @(posedge clk);#1;
  @(negedge clk);write=0;
 endtask
 task stage;
  for(integer k=0;k<6;k++)begin
   put(6'(8+4*k),32'(k+1));
   if(context_valid || epoch!=0 || session!=0)$fatal(1,"partial context exposed");
  end
 endtask
 initial begin
  reset();stage();put(0,32'ha10e0001);
  if(!context_valid || fault || epoch!==64'h0000000200000001 ||
     session!==128'h00000006000000050000000400000003)$fatal(1,"atomic context");
  put(8,99);
  if(context_valid || !fault || epoch!==64'h0000000200000001)$fatal(1,"immutable context");
  reset();put(0,32'ha10e0001);stage();put(0,32'ha10e0001);
  if(context_valid || !fault)$fatal(1,"incomplete commit replayed");
  reset();put(8,1,1);
  if(!fault || context_valid)$fatal(1,"partial write accepted");
  reset();stage();put(8,0);put(12,0);put(0,32'ha10e0001);
  if(!fault || context_valid)$fatal(1,"zero epoch accepted");
  reset();stage();for(integer k=2;k<6;k++)put(6'(8+4*k),0);put(0,32'ha10e0001);
  if(!fault || context_valid)$fatal(1,"zero session accepted");
  reset();stage();put(0,32'ha10e0001);
  @(negedge clk);read=1;address=8;@(posedge clk);#1;
  if(!readdatavalid || readdata!=1)$fatal(1,"readback mismatch");
  @(negedge clk);read=0;reset();
  if(context_valid || fault || epoch!=0 || session!=0)$fatal(1,"cold reset failed");
  $display("CONTEXT_MAILBOX_PASS atomic immutable incomplete partial zero readback reset");$finish;
 end
endmodule
