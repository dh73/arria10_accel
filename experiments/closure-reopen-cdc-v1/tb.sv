module tb;
 logic kc=0,pc=0;always #5 kc=~kc;always #7 pc=~pc;
 logic rst=0,consume=0,rd=0,wr=0,permit_ack=1;
 logic [5:0] addr=0;logic [31:0] data=0;
 wire kr,pr,cf,req,ack,rv,closed,mf;wire [63:0] req_round,round;wire [31:0] rdata;
 localparam logic [191:0] ID={128'h123456789abcdef00123456789abcdef,64'hfedcba9800000009};
 closure_reopen_cdc crossing(kc,pc,rst,consume,kr,cf,req,req_round,ack&&permit_ack,pr);
 upstream_closure_mailbox mailbox(.clk(pc),.cold_reset_n(rst),.context_valid(1'b1),.context_fault(1'b0),
 .context_identity(ID),.read(rd),.write(wr),.address(addr),.writedata(data),.byteenable(4'hf),
 .readdatavalid(rv),.readdata(rdata),.reopen_request(req),.reopen_round(req_round),.reopen_ack(ack),
 .round,.upstream_closed(closed),.fault(mf));
 task put(input int a,input logic [31:0] d);
  @(negedge pc);wr=1;addr=6'(a);data=d;@(negedge pc);wr=0;
 endtask
 task close_round(input logic [63:0] r);
  logic [255:0] tuple;tuple={r,ID};
  for(int i=0;i<8;i++)put(8+4*i,tuple[32*i+:32]);put(40,32'ha10b0001);
  assert(closed&&!mf)else $fatal(1,"closure");
 endtask
 task pulse;
  @(negedge kc);consume=1;@(negedge kc);consume=0;
 endtask
 task reset;
  rst=0;consume=0;wr=0;permit_ack=1;
  repeat(3)@(negedge kc);rst=1;repeat(3)@(negedge pc);
  assert(!kr&&!pr&&!cf&&!mf&&round==1)else $fatal(1,"reset");
 endtask
 initial begin
  reset();close_round(1);permit_ack=0;pulse();wait(ack);
  repeat(12)begin @(negedge pc);assert(req&&req_round==1&&round==2&&!pr&&!kr&&!mf)else $fatal(1,"held request");end
  permit_ack=1;wait(kr);wait(pr);
  assert(!req&&!ack&&round==2&&!closed&&!cf&&!mf)else $fatal(1,"first reopen");
  close_round(2);pulse();wait(!kr);wait(kr);wait(pr);
  assert(round==3&&!closed&&!cf&&!mf)else $fatal(1,"second reopen");
  reset();close_round(1);permit_ack=0;pulse();wait(ack);pulse();
  repeat(8)@(negedge pc);assert(cf&&!kr&&!pr&&round==2)else $fatal(1,"overlap accepted");
  reset();close_round(1);pulse();wait(req);reset();
  assert(!req&&!ack&&!kr&&!pr&&round==1)else $fatal(1,"reset in flight");
  $display("CLOSURE_REOPEN_CDC_PASS two_rounds held_ack overlapping_event cold_reset");$finish;
 end
endmodule
