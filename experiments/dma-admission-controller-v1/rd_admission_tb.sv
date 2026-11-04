`timescale 1ns/1ps
module rd_admission_tb;
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
logic  FetchFabricFault_i='0;
logic [7:0] FetchFabricReason_i='0;
logic [31:0] FetchFabricEpoch_i='0;
logic [19:0] FetchFabricToken_i='0;
logic [7:0] FetchFabricIndex_i='0;
logic  FetchEnable_i='0;
logic [31:0] FetchEpoch_i='0;
logic  FetchBindValid_i='0;
logic [159:0] FetchBindData_i='0;
logic [19:0] FetchBindToken_i='0;
logic [31:0] DTSFetchEpoch_i='0;
logic [19:0] DTSFetchToken_i='0;
logic [6:0] DTSFetchIndex_i='0;
logic  WrDTSChipSelect_i='0;
logic  WrDTSWrite_i='0;
logic [255:0] WrDTSWriteData_i='0;
wire  WrDTSWaitRequest_o;
logic [31:0] WrDTSFetchEpoch_i='0;
logic [19:0] WrDTSFetchToken_i='0;
logic [6:0] WrDTSFetchIndex_i='0;
wire  WriteDescValid_o;
wire [159:0] WriteDescData_o;
logic  WriteDescReady_i='0;
logic  FetchEndValid_i='0;
wire  FetchEndReady_o;
logic [31:0] FetchEndEpoch_i='0;
logic [19:0] FetchEndToken_i='0;
logic  FetchEndError_i='0;
logic  FetchAbortValid_i='0;
wire  FetchAbortReady_o;
logic [31:0] FetchAbortEpoch_i='0;
logic [19:0] FetchAbortToken_i='0;
wire  FetchIssueValid_o;
wire [159:0] FetchIssueData_o;
wire [7:0] FetchIssueFirstId_o;
wire  FetchFault_o;
wire [7:0] FetchFaultReason_o;
wire [31:0] FetchFaultEpoch_o;
wire [19:0] FetchFaultToken_o;
wire [7:0] FetchFaultIndex_o;
wire  FetchLocalErrorValid_o;
logic  FetchLocalErrorReady_i='0;
wire [31:0] FetchLocalErrorEpoch_o;
wire [19:0] FetchLocalErrorToken_o;
wire [7:0] FetchLocalErrorReason_o;
wire [7:0] FetchLocalErrorCount_o;
logic [159:0] WrDescTxData_i='0;
wire  DmaRxReady_o;
wire  DmaAckValid_o;
wire [31:0] DmaAckData_o;
logic  DmaAckConsumed_i='0;
wire  FetchStatusValid_o;
wire [31:0] FetchStatusData_o;
wire  FetchStatusReady_o;
wire  StatusDiagnosticValid_o;
logic  StatusDiagnosticReady_i='0;
wire [31:0] StatusDiagnosticData_o;
wire  StatusProtocolFault_o;
wire [31:0] StatusProtocolFaultWord_o;
logic submit_permit=0,stop_req=1,upstream_closed=0;
 wire write_owned,stop_ack;
 always #5 Clk_i=~Clk_i;
 int captures=0,accepts=0,held_cycles=0;
dma_rd_admission_controller #(.READ_CONTROL(1)) dut(.*);
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
 FetchEnable_i=1;FetchEpoch_i=32'h1234;
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
 wait(DmaTxValid_o);@(negedge Clk_i);
 repeat(5)begin
  assert(DmaTxValid_o&&DmaTxData_o[153]&&FetchEnable_i&&!FetchFault_o)
   else $fatal(1,"stopped accepted fetch not retained");tick();
 end
 assert(captures==3&&accepts==3&&held_cycles>=2&&stop_ack)
  else $fatal(1,"native admission accounting mismatch captures=%d accepts=%d",captures,accepts);
 $display("ADMISSION_CONTROLLER_PASS rd captures=%0d accepts=%0d held=%0d pending_fetch=1",captures,accepts,held_cycles);
 $finish;
end
endmodule
