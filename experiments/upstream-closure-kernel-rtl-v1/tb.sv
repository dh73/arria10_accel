module tb;
 logic clk=0;always #5 clk=~clk;
 logic rst=0,rd=0,wr=0,reopen=0;
 logic [5:0] addr=0;logic [31:0] data=0;
 logic [63:0] reopen_round=0;
 wire rv,ack,closed,fault;wire [31:0] rdata;wire [63:0] round;
 upstream_closure_mailbox dut(
  .clk,.cold_reset_n(rst),.context_valid(1'b1),.context_fault(1'b0),
  .context_identity({128'h00000004000000030000000200000001,64'hfedcba9800000009}),
  .read(rd),.write(wr),.address(addr),.writedata(data),.byteenable(4'hf),
  .readdatavalid(rv),.readdata(rdata),.reopen_request(reopen),.reopen_round,
  .reopen_ack(ack),.round,.upstream_closed(closed),.fault);
 export "DPI-C" task closure_reset;
 export "DPI-C" task closure_get;
 export "DPI-C" task closure_put;
 export "DPI-C" task closure_reopen;
 import "DPI-C" context task run_closure(output int result);
 task closure_reset;
  @(negedge clk);rst=0;rd=0;wr=0;reopen=0;
  repeat(3)@(negedge clk);rst=1;@(negedge clk);
 endtask
 task closure_get(input int unsigned a,output int unsigned v);
  assert(a<48&&a[1:0]==0)else $fatal(1,"read range");
  @(negedge clk);addr=6'(a);rd=1;@(negedge clk);
  assert(rv)else $fatal(1,"missing read response");v=rdata;rd=0;
 endtask
 task closure_put(input int unsigned a,input int unsigned v);
  assert(a<48&&a[1:0]==0)else $fatal(1,"write range");
  @(negedge clk);addr=6'(a);data=v;wr=1;@(negedge clk);wr=0;
 endtask
 task closure_reopen(input longint unsigned n);
  @(negedge clk);reopen_round=n;reopen=1;@(negedge clk);
  assert(ack&&!closed&&!fault&&round==n+1)else $fatal(1,"reopen failed");
  reopen=0;@(negedge clk);assert(!ack)else $fatal(1,"ack retained");
 endtask
 initial begin
  int result;run_closure(result);
  assert(result==0&&!fault)else $fatal(1,"kernel closure protocol failed");
  $display("UPSTREAM_CLOSURE_COMPOSITION_PASS");$finish;
 end
endmodule
