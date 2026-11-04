`timescale 1ns/1ps
module writeback_host_rtl_tb;
 logic pcie_clk=0,clk=0,reset_n=0;always #7 pcie_clk=~pcie_clk;always #5 clk=~clk;
 logic s_read=0,s_write=0;logic [63:0] s_address=0;logic [31:0] s_writedata=0;
 wire s_waitrequest,s_readdatavalid;wire [31:0] s_readdata;
 wire read,write;wire [63:0] full_address;wire [31:0] writedata;wire [3:0] byteenable;
 wire readdatavalid;wire [31:0] readdata;wire ready,settled,fault;
 logic write_permit=1;wire cmd_valid,busy;wire [2:0] cmd_op;
 logic cmd_ready=1,cmd_done=0,cmd_accepted=0;logic [3:0] cmd_reason=0;
 int commits=0,offers=0,reads=0,writes=0,fixture_reason=0;
 always @(posedge clk)begin
  if(!reset_n)begin cmd_done<=0;cmd_accepted<=0;cmd_reason<=0;end
  else begin
   cmd_done<=cmd_valid&&cmd_ready;
   if(cmd_valid&&cmd_ready)begin offers++;cmd_accepted<=fixture_reason==0;cmd_reason<=4'(fixture_reason);end
  end
 end
 pio_cdc_bridge bridge(.src_clk(pcie_clk),.dst_clk(clk),.common_cold_reset_n(reset_n),
  .s_read,.s_write,.s_address,.s_writedata,.s_byteenable(4'hf),.s_waitrequest,.s_readdatavalid,.s_readdata,
  .m_read(read),.m_write(write),.m_address(full_address),.m_writedata(writedata),.m_byteenable(byteenable),
  .m_waitrequest(1'b0),.m_readdatavalid(readdatavalid),.m_readdata(readdata));
 supervisor_command_mailbox dut(.clk,.cold_reset_n(reset_n),.write_permit,
 .read,.write,.address(full_address[4:0]),.writedata,.byteenable,.readdatavalid,.readdata,
 .invalid_access(),.cmd_valid,.cmd_op,.cmd_ready,.cmd_done,.cmd_accepted,.cmd_reason,.busy);
 always @(posedge clk)if(reset_n)begin
  if(read)reads++;
  if(write)begin writes++;if(full_address[4:0]==12)commits++;end
 end
 import "DPI-C" context task run_control_host(output int result);
 export "DPI-C" task control_reset;
 export "DPI-C" task control_put;
 export "DPI-C" task control_get;
 export "DPI-C" task control_observe;
 task control_reset(input int why);
  @(negedge clk);reset_n=0;s_read=0;s_write=0;commits=0;offers=0;reads=0;writes=0;fixture_reason=why;
  repeat(4)@(negedge pcie_clk);reset_n=1;repeat(4)@(negedge pcie_clk);
 endtask
 task control_put(input longint unsigned a,input int unsigned d);
  @(negedge pcie_clk);s_address=a;s_writedata=d;s_write=1;
  do @(posedge pcie_clk);while(s_waitrequest);
  @(negedge pcie_clk);s_write=0;wait(!s_waitrequest);
 endtask
 task control_get(input longint unsigned a,output int unsigned d);
  @(negedge pcie_clk);s_address=a;s_read=1;
  do @(posedge pcie_clk);while(s_waitrequest);
  @(negedge pcie_clk);s_read=0;
  wait(s_readdatavalid);if($isunknown(s_readdata))$fatal(1,"unknown fence response");
  d=s_readdata;@(negedge pcie_clk);
 endtask
 task control_observe(output int accepted_offers,output int commands);
  repeat(4)@(negedge clk);accepted_offers=offers;commands=commits;
 endtask
 initial begin
  int result;run_control_host(result);
  if(result!=0)$fatal(1,"C++/ACLPCI/CDC/supervisor command failed");
  $display("SUPERVISOR_HOST_RTL_PASS");$finish;
 end
endmodule
