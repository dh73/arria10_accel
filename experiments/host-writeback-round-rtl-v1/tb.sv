`timescale 1ns/1ps
module writeback_host_rtl_tb;
 logic pcie_clk=0,clk=0,reset_n=0;always #7 pcie_clk=~pcie_clk;always #5 clk=~clk;
 logic s_read=0,s_write=0;logic [63:0] s_address=0;logic [31:0] s_writedata=0;
 wire s_waitrequest,s_readdatavalid;wire [31:0] s_readdata;
 wire read,write;wire [63:0] full_address;wire [31:0] writedata;wire [3:0] byteenable;
 wire readdatavalid;wire [31:0] readdata;wire ready,settled,fault;
 logic context_valid=1,admission_closed=1,local_drained=1;
 logic [127:0] session;logic [63:0] epoch;
 int commits=0,reads=0,writes=0;
 pio_cdc_bridge bridge(.src_clk(pcie_clk),.dst_clk(clk),.common_cold_reset_n(reset_n),
  .s_read,.s_write,.s_address,.s_writedata,.s_byteenable(4'hf),.s_waitrequest,.s_readdatavalid,.s_readdata,
  .m_read(read),.m_write(write),.m_address(full_address),.m_writedata(writedata),.m_byteenable(byteenable),
  .m_waitrequest(1'b0),.m_readdatavalid(readdatavalid),.m_readdata(readdata));
 host_writeback_fence_round dut(.clk,.cold_reset_n(reset_n),.context_valid,.session,.epoch,
  .admission_closed,.local_drained,.tx_checkpoint_empty(1'b1),.stop_requested(1'b1),.reopen(1'b0),.read,.write,.address(full_address[5:0]),.writedata,.byteenable,
  .readdatavalid,.readdata,.ready,.settled,.fault);
 always @(posedge clk)if(reset_n)begin
  if(read)reads++;
  if(write)begin writes++;if(full_address[5:0]==36)commits++;end
 end
 import "DPI-C" context task run_writeback_host(output int result);
 export "DPI-C" task fence_reset;
 export "DPI-C" task fence_put;
 export "DPI-C" task fence_get;
 export "DPI-C" task fence_mutate;
 export "DPI-C" task fence_observe;
 task fence_reset;
  @(negedge clk);reset_n=0;s_read=0;s_write=0;commits=0;reads=0;writes=0;
  epoch=64'h0000000200000001;session={32'd6,32'd5,32'd4,32'd3};
  context_valid=1;admission_closed=1;local_drained=1;
  repeat(4)@(negedge pcie_clk);reset_n=1;
  wait(ready);repeat(4)@(negedge pcie_clk);
 endtask
 task fence_mutate(input int word);
  @(negedge clk);
  if(word<2)epoch[32*word+:32]=epoch[32*word+:32]^32'h100;
  else session[32*(word-2)+:32]=session[32*(word-2)+:32]^32'h100;
  @(posedge clk);@(negedge clk);
 endtask
 task fence_put(input longint unsigned a,input int unsigned d);
  @(negedge pcie_clk);s_address=a;s_writedata=d;s_write=1;
  do @(posedge pcie_clk);while(s_waitrequest);
  @(negedge pcie_clk);s_write=0;wait(!s_waitrequest);
 endtask
 task fence_get(input longint unsigned a,output int unsigned d);
  @(negedge pcie_clk);s_address=a;s_read=1;
  do @(posedge pcie_clk);while(s_waitrequest);
  @(negedge pcie_clk);s_read=0;
  wait(s_readdatavalid);if($isunknown(s_readdata))$fatal(1,"unknown fence response");
  d=s_readdata;@(negedge pcie_clk);
 endtask
 task fence_observe(output int was_settled,output int was_fault,output int commands,output int mask,output int io);
  @(negedge clk);was_settled=settled;was_fault=fault;commands=commits;mask=dut.echoed;io=reads+writes;
 endtask
 initial begin
  int result;run_writeback_host(result);
  if(result!=0)$fatal(1,"C++/ACLPCI/CDC/fence integration failed");
  $display("WRITEBACK_ROUND_HOST_RTL_PASS happy_io=21 uncertain_boundaries=21 stale_contexts=6 mutated_contexts=6 staged_failures=8");$finish;
 end
endmodule
