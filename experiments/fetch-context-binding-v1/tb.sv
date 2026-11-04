module tb;
 logic kclk=0,pclk=0,reset_n=0,live=0;
 always #5 kclk=~kclk;
 always #7 pclk=~pclk;
 logic [127:0] session=0;
 logic [63:0] epoch=0;
 wire valid,fault,ready;wire [31:0] token;
 fetch_context_binding dut(kclk,pclk,reset_n,live,session,epoch,valid,token,fault,ready);
 task settle;repeat(32)@(negedge pclk);endtask
 task reset;
  reset_n=0;live=0;session=0;epoch=0;
  repeat(3)@(negedge pclk);assert(!valid&&!ready&&!fault&&token==0)else $fatal(1,"reset");
  reset_n=1;settle();
 endtask
 task bind_high;
  @(negedge kclk);session=128'h123456789abcdef_0123456789abcdef;epoch=64'hfedcba9800000009;live=1;
  settle();assert(valid&&ready&&!fault&&token==1)else $fatal(1,"full-width binding");
 endtask
 initial begin
  reset();assert(!valid&&!ready&&!fault)else $fatal(1,"premature binding");
  bind_high();
  @(negedge kclk);live=0;settle();
  assert(valid&&token==1&&fault&&!ready)else $fatal(1,"withdrawal lost custody");
  live=1;settle();assert(fault&&!ready&&valid&&token==1)else $fatal(1,"fault recovered");
  reset();bind_high();
  @(negedge kclk);epoch=64'h1234567800000009;settle();
  assert(valid&&token==1&&fault&&!ready)else $fatal(1,"high epoch mismatch missed");
  reset();bind_high();
  @(negedge kclk);session=session^128'h10000000000000000000000000000000;settle();
  assert(valid&&token==1&&fault&&!ready)else $fatal(1,"session mismatch missed");
  reset();@(negedge kclk);live=1;session=1;epoch=0;settle();
  assert(!valid&&fault&&!ready&&token==0)else $fatal(1,"zero epoch admitted");
  epoch=1;settle();assert(!valid&&fault&&!ready)else $fatal(1,"invalid binding retried");
  reset();@(negedge kclk);live=1;session=0;epoch=1;settle();
  assert(!valid&&fault&&!ready&&token==0)else $fatal(1,"zero session admitted");
  reset();bind_high();
  $display("FETCH_CONTEXT_BINDING_PASS full_epoch separate_token sticky_custody mismatch reset");$finish;
 end
endmodule
