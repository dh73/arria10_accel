`timescale 1ns/1ps
module wr_admission_tb;
logic  Clk_i='0;
logic  Rstn_i='0;
logic [81:0] MsiInterface_i='0;
logic  DCSChipSelect_i='0;
logic  DCSWrite_i='0;
logic [7:0] DCSAddress_i='0;
logic [31:0] DCSWriteData_i='0;
logic [3:0] DCSByteEnable_i='0;
logic  DCSRead_i='0;
wire [31:0] DCSReadData_o;
wire  DCSWaitRequest_o;
wire [63:0] DCMAddress_o;
wire  DCMWrite_o;
wire [31:0] DCMWriteData_o;
wire  DCMRead_o;
wire [3:0] DCMByteEnable_o;
logic  DCMWaitRequest_i='0;
logic [31:0] DCMReadData_i='0;
logic  DCMReadDataValid_i='0;
logic  DTSChipSelect_i='0;
logic  DTSWrite_i='0;
logic [4:0] DTSBurstCount_i='0;
logic [7:0] DTSAddress_i='0;
logic [255:0] DTSWriteData_i='0;
wire  DTSWaitRequest_o;
wire [159:0] DmaTxData_o;
wire  DmaTxValid_o;
logic  DmaTxReady_i='0;
logic [31:0] DmaRxData_i='0;
logic  DmaRxValid_i='0;
wire [159:0] WrDescTxData_o;
wire  WrDescTxReq_o;
logic  WrDescTxAck_i='0;
wire  WrDescTxAck_o;
logic  WrDescTxReq_i='0;
logic [7:0] WrDescFirstId_i='0;
wire [7:0] WrDescFirstId_o;
logic [159:0] WrDescTxData_i='0;
wire  RetireFault_o;
wire [31:0] RetireFaultData_o;
wire [7:0] RetireExpectedId_o;
wire  RetireBusy_o;
logic submit_permit=0,stop_req=1,upstream_closed=0;
 wire write_owned,stop_ack;
 always #5 Clk_i=~Clk_i;
 int captures=0,accepts=0,held_cycles=0;
dma_wr_admission_controller #(.READ_CONTROL(0)) dut(.*);
always @(posedge Clk_i)if(Rstn_i)begin
 if(dut.gate.capture_write)captures++;
 if(dut.m_select&&dut.m_write&&!dut.m_waitrequest)accepts++;
 if(write_owned&&stop_req)begin
  held_cycles++;
  assert(!stop_ack)else $fatal(1,"stop acknowledged owned write");
 end
end
task automatic tick;@(posedge Clk_i);@(negedge Clk_i);#1;endtask
task automatic finish_write;
 while(DCSWaitRequest_o)tick();
 tick();DCSChipSelect_i=0;DCSWrite_i=0;
endtask
task automatic csr_read(input logic [7:0] a,input logic [31:0] expected);
 DCSChipSelect_i=1;DCSRead_i=1;DCSAddress_i=a;#1;
 while(DCSWaitRequest_o)tick();
 assert(DCSReadData_o===expected)else $fatal(1,"stopped CSR read mismatch %h != %h",DCSReadData_o,expected);
 tick();DCSChipSelect_i=0;DCSRead_i=0;
endtask
task automatic capture_then_stop(input logic [7:0] a,input logic [31:0] value);
 submit_permit=1;stop_req=0;upstream_closed=0;
 DCSChipSelect_i=1;DCSWrite_i=1;DCSAddress_i=a;DCSWriteData_i=value;#1;
 assert(write_owned&&DCSWaitRequest_o)else $fatal(1,"capture ownership absent");
 tick();stop_req=1;submit_permit=0;#1;
 assert(dut.m_write&&dut.m_waitrequest&&write_owned&&!stop_ack)else $fatal(1,"native ACK was not pending at stop");
 upstream_closed=1;#1;assert(!stop_ack)else $fatal(1,"certificate bypassed retained write");
 finish_write();#1;assert(stop_ack&&!write_owned)else $fatal(1,"accepted write not released");
endtask
initial begin
 DCSByteEnable_i=15;DCMWaitRequest_i=1;
 repeat(4)tick();Rstn_i=1;repeat(3)tick();
 assert(!stop_ack)else $fatal(1,"fabricated upstream certificate");
 capture_then_stop(8'h00,32'h8000);csr_read(0,32'h8000);
 // A later write is held by the master while stopped, then accepted on resume.
 upstream_closed=0;DCSChipSelect_i=1;DCSWrite_i=1;DCSAddress_i=0;DCSWriteData_i=32'h9000;
 repeat(5)begin tick();assert(DCSWaitRequest_o&&!write_owned&&!stop_ack&&accepts==1)else $fatal(1,"later write escaped stop");end
 stop_req=0;submit_permit=1;finish_write();stop_req=1;submit_permit=0;upstream_closed=1;
 csr_read(0,32'h9000);
 // A real descriptor doorbell is retained through the native DCS pipeline.
 capture_then_stop(8'h10,32'd0);
 wait(WrDescTxReq_o);@(negedge Clk_i);
 repeat(5)begin
  assert(WrDescTxReq_o&&WrDescTxData_o[153]&&!RetireFault_o)
   else $fatal(1,"stopped accepted write fetch not retained");tick();
 end
 assert(captures==3&&accepts==3&&held_cycles>=2&&stop_ack)
  else $fatal(1,"native admission accounting mismatch captures=%d accepts=%d",captures,accepts);
 $display("ADMISSION_CONTROLLER_PASS wr captures=%0d accepts=%0d held=%0d pending_fetch=1",captures,accepts,held_cycles);
 $finish;
end
endmodule
