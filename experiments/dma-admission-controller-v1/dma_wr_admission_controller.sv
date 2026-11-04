module dma_wr_admission_controller #(
      parameter                                    READ_CONTROL = 0,
      parameter                                    dma_use_scfifo_ext = 0,
      parameter                                    DMA_WIDTH = 256
 ) (
      input logic submit_permit,stop_req,upstream_closed,
 output wire write_owned,stop_ack,
 input logic                                   Clk_i,
      input logic                                   Rstn_i,
      input logic   [81:0]                          MsiInterface_i,

      // AVMM Register Slave Port (Write only)
      input  logic                                  DCSChipSelect_i,
      input  logic                                  DCSWrite_i,
      input  logic  [7:0]                           DCSAddress_i,
      input  logic  [31:0]                          DCSWriteData_i,
      input  logic  [3:0]                           DCSByteEnable_i,
      input  logic                                  DCSRead_i,
      output logic  [31:0]                          DCSReadData_o,
      output logic                                  DCSWaitRequest_o,


      // AVMM Register Master Port (Write only)

      output   logic [63:0]                         DCMAddress_o,
      output                                        DCMWrite_o,
      output   logic [31:0]                         DCMWriteData_o,
      output                                        DCMRead_o,
      output   logic [3:0]                          DCMByteEnable_o,
      input    logic                                DCMWaitRequest_i,
      input    logic [31:0]                         DCMReadData_i,
      input    logic                                DCMReadDataValid_i,

      /// DT 256-bit slave interface (Write only)

      input  logic                                  DTSChipSelect_i,
      input  logic                                  DTSWrite_i,
      input  logic  [4:0]                           DTSBurstCount_i,
      input  logic  [7:0]                           DTSAddress_i,
      input  logic  [255:0]                         DTSWriteData_i,
      output logic                                  DTSWaitRequest_o,

      /// DMA programming interface
      output   logic  [159:0]                       DmaTxData_o,
      output   logic                                DmaTxValid_o,
      input    logic                                DmaTxReady_i,

     // DMA Status Interface
      input   logic  [31:0]                         DmaRxData_i,
      input   logic                                 DmaRxValid_i,

      /// Exclusive Descriptor Fetch AST

      output   logic  [159:0]                       WrDescTxData_o,
      output   logic                                WrDescTxReq_o,
      input    logic                                WrDescTxAck_i,
      output   logic                                WrDescTxAck_o,
      input    logic                                WrDescTxReq_i,
      
input logic [7:0] WrDescFirstId_i,
output logic [7:0] WrDescFirstId_o,
input logic [159:0] WrDescTxData_i,
output wire RetireFault_o,
output wire [31:0] RetireFaultData_o,
output wire [7:0] RetireExpectedId_o,
output wire RetireBusy_o );
 wire m_select,m_read,m_write,m_waitrequest;
 wire [7:0] m_address;wire [31:0] m_writedata,m_readdata;wire [3:0] m_byteenable;
 dma_admission_gate gate(.clk(Clk_i),.reset_n(Rstn_i),.submit_permit,.stop_req,.upstream_closed,
  .s_select(DCSChipSelect_i),.s_read(DCSRead_i),.s_write(DCSWrite_i),.s_address(DCSAddress_i),
  .s_writedata(DCSWriteData_i),.s_byteenable(DCSByteEnable_i),.s_waitrequest(DCSWaitRequest_o),.s_readdata(DCSReadData_o),
  .m_select,.m_read,.m_write,.m_address,.m_writedata,.m_byteenable,.m_waitrequest,.m_readdata,.write_owned,.stop_ack);
altpcie_dynamic_control_write_d2h_v1 #(.READ_CONTROL(READ_CONTROL),.DMA_WIDTH(DMA_WIDTH),.dma_use_scfifo_ext(dma_use_scfifo_ext)) controller(
.Clk_i(Clk_i),
.Rstn_i(Rstn_i),
.MsiInterface_i(MsiInterface_i),
.DCSChipSelect_i(m_select),
.DCSWrite_i(m_write),
.DCSAddress_i(m_address),
.DCSWriteData_i(m_writedata),
.DCSByteEnable_i(m_byteenable),
.DCSRead_i(m_read),
.DCSReadData_o(m_readdata),
.DCSWaitRequest_o(m_waitrequest),
.DCMAddress_o(DCMAddress_o),
.DCMWrite_o(DCMWrite_o),
.DCMWriteData_o(DCMWriteData_o),
.DCMRead_o(DCMRead_o),
.DCMByteEnable_o(DCMByteEnable_o),
.DCMWaitRequest_i(DCMWaitRequest_i),
.DCMReadData_i(DCMReadData_i),
.DCMReadDataValid_i(DCMReadDataValid_i),
.DTSChipSelect_i(DTSChipSelect_i),
.DTSWrite_i(DTSWrite_i),
.DTSBurstCount_i(DTSBurstCount_i),
.DTSAddress_i(DTSAddress_i),
.DTSWriteData_i(DTSWriteData_i),
.DTSWaitRequest_o(DTSWaitRequest_o),
.DmaTxData_o(DmaTxData_o),
.DmaTxValid_o(DmaTxValid_o),
.DmaTxReady_i(DmaTxReady_i),
.DmaRxData_i(DmaRxData_i),
.DmaRxValid_i(DmaRxValid_i),
.WrDescTxData_o(WrDescTxData_o),
.WrDescTxReq_o(WrDescTxReq_o),
.WrDescTxAck_i(WrDescTxAck_i),
.WrDescTxAck_o(WrDescTxAck_o),
.WrDescTxReq_i(WrDescTxReq_i),
.WrDescFirstId_i(WrDescFirstId_i),
.WrDescFirstId_o(WrDescFirstId_o),
.WrDescTxData_i(WrDescTxData_i),
.RetireFault_o(RetireFault_o),
.RetireFaultData_o(RetireFaultData_o),
.RetireExpectedId_o(RetireExpectedId_o),
.RetireBusy_o(RetireBusy_o));
endmodule
