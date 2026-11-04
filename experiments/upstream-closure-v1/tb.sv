module tb;
 logic clk=0;always #5 clk=~clk;
 logic rst=0,valid=0,context_fault=0,rd=0,wr=0,reopen=0;
 logic [191:0] identity=0;
 logic [5:0] addr=0;logic [31:0] data=0;logic [3:0] mask=15;
 logic [63:0] reopen_round=0;
 wire rv,ack,closed,fault;wire [31:0] rdata;wire [63:0] round;
 upstream_closure_mailbox dut(clk,rst,valid,context_fault,identity,rd,wr,addr,data,mask,rv,rdata,reopen,reopen_round,ack,round,closed,fault);
 task reset;
  rst=0;valid=0;context_fault=0;rd=0;wr=0;reopen=0;mask=15;
  repeat(2)@(negedge clk);rst=1;
  identity={128'h123456789abcdef00123456789abcdef,64'hfedcba9800000009};valid=1;
  @(negedge clk);assert(round==1&&!closed&&!fault&&!ack)else $fatal(1,"reset");
 endtask
 task put(input int a,input logic [31:0] v);
  @(negedge clk);wr=1;addr=6'(a);data=v;@(negedge clk);wr=0;
 endtask
 task commit(input logic [63:0] n);
  logic [255:0] tuple;tuple={n,identity};
  for(int i=0;i<8;i++)put(8+4*i,tuple[32*i+:32]);
  put(40,32'ha10b0001);
 endtask
 initial begin
  reset();commit(1);assert(closed&&!fault)else $fatal(1,"initial closure");
  @(negedge clk);reopen_round=1;reopen=1;@(negedge clk);
  assert(ack&&!closed&&round==2&&!fault)else $fatal(1,"reopen");
  repeat(3)@(negedge clk);assert(ack&&round==2)else $fatal(1,"repeated reopen");
  reopen=0;@(negedge clk);assert(!ack)else $fatal(1,"ack release");
  commit(2);assert(closed&&!fault)else $fatal(1,"second closure");
  reset();commit(2);assert(fault&&!closed)else $fatal(1,"future round accepted");
  reset();put(40,32'ha10b0001);assert(fault&&!closed)else $fatal(1,"partial tuple accepted");
  reset();mask=7;put(8,9);assert(fault&&!closed)else $fatal(1,"partial byte write accepted");
  reset();commit(1);reopen_round=2;reopen=1;@(negedge clk);@(negedge clk);
  assert(fault&&!ack)else $fatal(1,"wrong reopen accepted");
  reset();commit(1);context_fault=1;@(negedge clk);@(negedge clk);
  assert(fault&&!closed)else $fatal(1,"context loss ignored");
  reset();commit(1);reopen_round=1;reopen=1;@(negedge clk);@(negedge clk);reopen=0;@(negedge clk);
  commit(1);assert(fault&&!closed&&round==2)else $fatal(1,"stale close accepted");
  $display("UPSTREAM_CLOSURE_PASS full_context rounds stale partial fault reopen_handshake");$finish;
 end
endmodule
