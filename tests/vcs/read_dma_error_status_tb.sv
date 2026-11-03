`timescale 1ns/1ps
module read_dma_error_status_tb;
  logic clk=0,rstn=0,desc_valid=0,stall=1;
  logic [159:0] desc=0;
  wire ready,wr,rx_pop,tx_push,arb,tag_pop,status_valid;
  wire [63:0] addr;
  wire [255:0] data;
  wire [31:0] be,status_data,control_status;
  wire [4:0] burst;
  wire [259:0] tx;
  logic [265:0] packets[10];
  int offered=0,consumed=0,requests=0,beats=0,in_burst=0,statuses=0;
  bit premature=0;
  logic [7:0] tags[2];
  wire [265:0] rx = (consumed<offered)?packets[consumed]:266'b0;
  wire [3:0] rx_count=(consumed<offered)?4'd1:4'd0;
  always #5 clk=~clk;
  altpcieav_dma_rd #(.DMA_WIDTH(256),.DMA_BE_WIDTH(32),
    .RDDMA_AVL_ADDR_WIDTH(64),.DEVICE_FAMILY("Arria 10")) dut (
    .Clk_i(clk),.Rstn_i(rstn),.RdDmaWrite_o(wr),.RdDmaAddress_o(addr),
    .RdDmaWriteData_o(data),.RdDmaBurstCount_o(burst),.RdDmaWriteEnable_o(be),
    .RdDmaWaitRequest_i(stall),.RdDmaRxData_i(desc),.RdDmaRxValid_i(desc_valid),
    .RdDmaRxReady_o(ready),.RdDmaTxData_o(status_data),.RdDmaTxValid_o(status_valid),
    .RxFifoRdReq_o(rx_pop),.RxFifoDataq_i(rx),.RxFifoCount_i(rx_count),
    .PreDecodeTagRdReq_o(tag_pop),.PreDecodeTag_i(rx[79:72]),.PreDecodeTagCount_i(rx_count),
    .TxFifoWrReq_o(tx_push),.TxFifoData_o(tx),.TxFifoCount_i(4'b0),
    .RdDMACntrlLoad_i(1'b0),.RdDMACntrlData_i(32'b0),.RdDMAStatus_o(control_status),
    .RdDMmaArbReq_o(arb),.RdDMmaArbGranted_i(arb),.BusDev_i(13'h100),
    .DevCsr_i(32'b0),.MasterEnable_i(1'b0),.ko_cpl_spc_header(8'hff),
    .ko_cpl_spc_data(12'hfff));
  logic cs=0, cswrite=0;
  logic [7:0] csaddr=0;
  logic [31:0] csdata=0;
  wire cswait, host_write;
  wire [63:0] host_address;
  wire [31:0] host_data;
  altpcie_dynamic_control controller (
    .Clk_i(clk),.Rstn_i(rstn),.MsiInterface_i(82'b0),
    .DCSChipSelect_i(cs),.DCSWrite_i(cswrite),.DCSAddress_i(csaddr),
    .DCSWriteData_i(csdata),.DCSByteEnable_i(4'hf),.DCSRead_i(1'b0),
    .DCSReadData_o(),.DCSWaitRequest_o(cswait),
    .DCMAddress_o(host_address),.DCMWrite_o(host_write),.DCMWriteData_o(host_data),
    .DCMRead_o(),.DCMByteEnable_o(),.DCMWaitRequest_i(1'b0),
    .DCMReadData_i(32'b0),.DCMReadDataValid_i(1'b0),
    .DTSChipSelect_i(1'b0),.DTSWrite_i(1'b0),.DTSBurstCount_i(5'b0),
    .DTSAddress_i(8'b0),.DTSWriteData_i(256'b0),.DTSWaitRequest_o(),
    .DmaTxData_o(),.DmaTxValid_o(),.DmaTxReady_i(1'b1),
    .DmaRxData_i(status_data),.DmaRxValid_i(status_valid),
    .WrDescTxData_o(),.WrDescTxReq_o(),.WrDescTxAck_i(1'b0),
    .WrDescTxAck_o(),.WrDescTxReq_i(1'b0),.WrDescTxData_i(160'b0));
  task automatic write_control(input logic[7:0] a,input logic[31:0] v);
    @(negedge clk); csaddr=a; csdata=v; cs=1; cswrite=1;
    #1; while(cswait) begin @(negedge clk); #1; end
    @(posedge clk); @(negedge clk); cs=0; cswrite=0;
  endtask
  always @(posedge clk) if(rstn) begin
    if(tx_push || wr) $fatal(1,"master-disabled descriptor issued payload");
    if(status_valid) begin
      statuses++;
      $display("ERROR_STATUS requested_id=7 raw=%h completed_bit=%b",status_data,status_data[8]);
      if(status_data[8]!==1'b0) $fatal(1,"DMA unexpectedly marked error as complete");
    end
    if(host_write) begin
      $display("HOST_FLAG address=%h data=%h payload_requests=0",host_address,host_data);
      if(host_data==1) $fatal(1,"controller converts non-completion error status to success flag");
    end
  end
  initial begin
    repeat(5) @(negedge clk); rstn=1;
    // Normal controller register writes: header base and report every status.
    write_control(8'h00,32'h8000); write_control(8'h18,32'h1);
    @(negedge clk); while(!ready) @(negedge clk);
    desc[63:0]=64'h1000; desc[127:64]=64'h2000;
    desc[145:128]=18'd64; desc[153:146]=8'd7; desc_valid=1;
    @(negedge clk); desc_valid=0;
    wait(statuses==1);
    // A corrected explicit error transport will need its own completion event;
    // this reproducer terminates on the observed invalid success write.
    wait(host_write);
    @(posedge clk); #1;
    $fatal(1,"unexpected host status encoding");
  end
endmodule
