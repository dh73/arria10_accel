// SPDX-License-Identifier: BSD-3-Clause
`default_nettype none
// Isolated native fetch composition. All descriptor requests originate at DCS.
// The actual read controller owns its consumer/copier/status sink and native
// FIFO. The actual read mover owns command, tag, return, and status accounting.
// Test gates hold both sides of a boundary; they cannot manufacture a transfer.
// The write controller is the executable write-table destination. Its payload
// mover/status producer belongs to the independent D2H experiment.
module dma_fetch_composition_v1 (
  input wire clk, rstn, enable,
  input wire [31:0] epoch,
  input wire [1:0] dcs_cs, dcs_write, dcs_read,
  input wire [1:0][7:0] dcs_address,
  input wire [1:0][31:0] dcs_wdata,
  input wire [1:0][3:0] dcs_be,
  output wire [1:0][31:0] dcs_rdata,
  output wire [1:0] dcs_wait,
  output wire [1:0] dcm_write,
  output wire [1:0][63:0] dcm_address,
  output wire [1:0][31:0] dcm_data,
  output wire [1:0][3:0] dcm_be,
  input wire [1:0] dcm_wait,
  input wire [265:0] rx,
  input wire [3:0] rx_count,
  output wire rx_pop, tag_pop,
  output wire [259:0] tx,
  output wire tx_push,
  input wire [3:0] tx_count,
  input wire master_enable, grant_enable, control_load,
  input wire [31:0] control_data,
  output wire control_ready,
  input wire allow_admit, allow_data_admit, allow_status, allow_end,
  input wire allow_read_table, allow_write_table,
  output wire payload_write,
  output wire [63:0] payload_address,
  output wire [255:0] payload_data,
  output wire [31:0] payload_be,
  output wire [4:0] payload_burst,
  input wire payload_wait,
  output wire write_valid,
  output wire [159:0] write_data,
  input wire write_ready,
  input wire diag_ready, local_ready,
  output wire diagnostic_valid,
  output wire [31:0] diagnostic_word,
  output wire local_valid,
  output wire [31:0] local_epoch,
  output wire [19:0] local_token,
  output wire [7:0] local_reason, local_count,
  output wire contract_fault, fetch_fault, controller_fault
);
  // Readable boundary observations for the independent bench scoreboard.
  wire read_tx_valid, read_tx_ready;
  wire [159:0] read_tx_data;
  wire descriptor_valid, descriptor_ready;
  wire admission_gate;
  wire bind_valid;
  wire [159:0] bind_desc;
  wire [19:0] bind_token;
  wire fetch_issue_valid;
  wire [159:0] fetch_issue_data;
  wire [7:0] fetch_issue_first;
  wire forward_req, forward_ack;
  wire [159:0] forward_data;
  wire [7:0] forward_first;
  wire copy_valid, copy_ready, copy_wait;
  wire [159:0] copy_data;
  wire engine_write, engine_wait;
  wire [63:0] engine_address;
  wire [255:0] engine_data;
  wire [31:0] engine_be;
  wire [4:0] engine_burst;
  wire [31:0] return_epoch;
  wire [19:0] return_token;
  wire [63:0] return_base;
  wire [7:0] return_count;
  wire end_valid, end_ready, end_error, consumer_end_ready;
  wire [31:0] end_epoch;
  wire [19:0] end_token;
  wire engine_status_valid, engine_status_ready, controller_status_ready;
  wire [31:0] engine_status_word;
  wire ack_valid, ack_consumed;
  wire [31:0] ack_word;
  wire fetch_valid, fetch_ready;
  wire [31:0] fetch_word;
  wire [1:0] dts_write, dts_wait, controller_dts_write, controller_dts_wait;
  wire [1:0][255:0] dts_data;
  wire [1:0][31:0] dts_epoch;
  wire [1:0][19:0] dts_token;
  wire [1:0][6:0] dts_index;
  wire route_accept, route_busy;
  wire [63:0] beat_address;
  wire producer_fault, route_fault_now, route_fault;
  wire [7:0] producer_fault_reason, producer_fault_tag;
  wire [31:0] producer_fault_epoch;
  wire [19:0] producer_fault_token;
  wire [7:0] route_reason, route_reason_now;
  wire [31:0] route_fault_epoch;
  wire [19:0] route_fault_token;
  wire [63:0] route_fault_address;
  wire [7:0] fetch_fault_reason, fetch_fault_index;
  wire [31:0] fetch_fault_epoch, controller_fault_word;
  wire [19:0] fetch_fault_token;
  wire fabric_fault;
  wire [7:0] fabric_reason, fabric_index;
  wire [31:0] fabric_epoch;
  wire [19:0] fabric_token;
  wire arb;
  wire [31:0] unused_dma_status;

  assign admission_gate=allow_admit && (read_tx_data[153] || allow_data_admit);
  assign descriptor_valid=read_tx_valid && admission_gate;
  assign read_tx_ready=descriptor_ready && admission_gate;
  assign engine_status_ready=controller_status_ready && allow_status;
  assign end_ready=consumer_end_ready && allow_end;
  assign controller_dts_write[0]=dts_write[0] && allow_read_table;
  assign controller_dts_write[1]=dts_write[1] && allow_write_table;
  assign dts_wait[0]=controller_dts_wait[0] || !allow_read_table;
  assign dts_wait[1]=controller_dts_wait[1] || !allow_write_table;
  assign copy_ready=!copy_wait;

  // Match the actual containing v5 return-fabric priority and identity ABI.
  assign fabric_fault=route_fault_now || producer_fault;
  assign fabric_reason=route_fault_now ? (8'h40 | route_reason_now) :
                                        (8'h80 | producer_fault_reason);
  assign fabric_epoch=route_fault_now ? route_fault_epoch : producer_fault_epoch;
  assign fabric_token=route_fault_now ? route_fault_token : producer_fault_token;
  assign fabric_index=route_fault_now ? 8'hff : producer_fault_tag;

  altpcieav_dma_rd_fetch_return_v5 #(
    .DMA_WIDTH(256), .DMA_BE_WIDTH(32), .DMA_BRST_CNT_W(5),
    .RDDMA_AVL_ADDR_WIDTH(64), .DEVICE_FAMILY("Arria 10")
  ) producer (
    .Clk_i(clk), .Rstn_i(rstn), .FetchEnable_i(enable), .FetchEpoch_i(epoch),
    .RdDmaWrite_o(engine_write), .RdDmaAddress_o(engine_address),
    .RdDmaWriteData_o(engine_data), .RdDmaWriteEnable_o(engine_be),
    .RdDmaBurstCount_o(engine_burst), .RdDmaWaitRequest_i(engine_wait),
    .ReturnEpoch_o(return_epoch), .ReturnToken_o(return_token),
    .ReturnBase_o(return_base), .ReturnCount_o(return_count),
    .RdDmaRxData_i(read_tx_data), .RdDmaRxValid_i(descriptor_valid),
    .RdDmaRxReady_o(descriptor_ready), .FetchBindValid_o(bind_valid),
    .FetchBindData_o(bind_desc), .FetchBindToken_o(bind_token),
    .FetchEndValid_o(end_valid), .FetchEndReady_i(end_ready),
    .FetchEndEpoch_o(end_epoch), .FetchEndToken_o(end_token), .FetchEndError_o(end_error),
    .ReturnRouteFault_i(route_fault_now || fetch_fault),
    .ReturnFault_o(producer_fault), .ReturnFaultEpoch_o(producer_fault_epoch),
    .ReturnFaultToken_o(producer_fault_token), .ReturnFaultReason_o(producer_fault_reason),
    .ReturnFaultTag_o(producer_fault_tag),
    .RdDmaTxData_o(engine_status_word), .RdDmaTxValid_o(engine_status_valid),
    .RdDmaTxReady_i(engine_status_ready), .RdDmaAckValid_i(ack_valid),
    .RdDmaAckData_i(ack_word), .RdDmaAckConsumed_o(ack_consumed),
    .RxFifoRdReq_o(rx_pop), .RxFifoDataq_i(rx), .RxFifoCount_i(rx_count),
    .PreDecodeTagRdReq_o(tag_pop), .PreDecodeTag_i(rx[79:72]),
    .PreDecodeTagCount_i(rx_count), .TxFifoWrReq_o(tx_push), .TxFifoData_o(tx),
    .TxFifoCount_i(tx_count), .RdDMACntrlLoad_i(control_load), .RdDMACntrlData_i(control_data),
    .RdDMACntrlReady_o(control_ready), .RdDMAStatus_o(unused_dma_status),
    .ContractFault_o(contract_fault), .RdDMmaArbReq_o(arb),
    .RdDMmaArbGranted_i(arb && grant_enable), .BusDev_i(13'h100),
    .DevCsr_i(32'd0), .MasterEnable_i(master_enable),
    .ko_cpl_spc_header(8'hff), .ko_cpl_spc_data(12'hfff)
  );

  dma_fetch_return_route_v5 route (
    .clk(clk), .rstn(rstn), .enable(enable), .epoch(epoch),
    .inhibit(producer_fault || fetch_fault),
    .s_address(engine_address), .s_write(engine_write), .s_data(engine_data),
    .s_byteenable(engine_be), .s_burstcount(engine_burst),
    .s_epoch(return_epoch), .s_token(return_token), .s_base(return_base), .s_count(return_count),
    .s_waitrequest(engine_wait), .payload_address(payload_address), .payload_write(payload_write),
    .payload_data(payload_data), .payload_byteenable(payload_be), .payload_burstcount(payload_burst),
    .payload_waitrequest(payload_wait), .dts_write(dts_write), .dts_data(dts_data),
    .dts_epoch(dts_epoch), .dts_token(dts_token), .dts_index(dts_index), .dts_waitrequest(dts_wait),
    .fault_now(route_fault_now), .fault(route_fault), .fault_reason(route_reason),
    .fault_epoch(route_fault_epoch), .fault_token(route_fault_token), .fault_address(route_fault_address),
    .reason_now(route_reason_now), .beat_address(beat_address), .accept(route_accept), .busy(route_busy)
  );

  altpcie_dynamic_control_fetch_return_v5 #(.READ_CONTROL(1), .DMA_WIDTH(256)) read_controller (
    .Clk_i(clk), .Rstn_i(rstn), .MsiInterface_i(82'b0),
    .DCSChipSelect_i(dcs_cs[0]), .DCSWrite_i(dcs_write[0]), .DCSAddress_i(dcs_address[0]),
    .DCSWriteData_i(dcs_wdata[0]), .DCSByteEnable_i(dcs_be[0]), .DCSRead_i(dcs_read[0]),
    .DCSReadData_o(dcs_rdata[0]), .DCSWaitRequest_o(dcs_wait[0]),
    .DCMAddress_o(dcm_address[0]), .DCMWrite_o(dcm_write[0]), .DCMWriteData_o(dcm_data[0]),
    .DCMRead_o(), .DCMByteEnable_o(dcm_be[0]), .DCMWaitRequest_i(dcm_wait[0]),
    .DCMReadData_i(32'b0), .DCMReadDataValid_i(1'b0),
    .DTSChipSelect_i(controller_dts_write[0]), .DTSWrite_i(controller_dts_write[0]),
    .DTSBurstCount_i(5'd1), .DTSAddress_i(8'd0), .DTSWriteData_i(dts_data[0]),
    .DTSWaitRequest_o(controller_dts_wait[0]),
    .DmaTxData_o(read_tx_data), .DmaTxValid_o(read_tx_valid), .DmaTxReady_i(read_tx_ready),
    .DmaRxData_i(engine_status_word), .DmaRxValid_i(engine_status_valid && allow_status),
    .DmaRxReady_o(controller_status_ready), .DmaAckValid_o(ack_valid),
    .DmaAckData_o(ack_word), .DmaAckConsumed_i(ack_consumed),
    .WrDescTxData_o(), .WrDescTxReq_o(), .WrDescTxAck_i(1'b0),
    .WrDescTxAck_o(forward_ack), .WrDescTxReq_i(forward_req), .WrDescTxData_i(forward_data),
    .WrDescFirstId_i(forward_first), .WrDescFirstId_o(),
    .FetchFabricFault_i(fabric_fault), .FetchFabricReason_i(fabric_reason),
    .FetchFabricEpoch_i(fabric_epoch), .FetchFabricToken_i(fabric_token), .FetchFabricIndex_i(fabric_index),
    .FetchEnable_i(enable), .FetchEpoch_i(epoch), .FetchBindValid_i(bind_valid),
    .FetchBindData_i(bind_desc), .FetchBindToken_i(bind_token),
    .DTSFetchEpoch_i(dts_epoch[0]), .DTSFetchToken_i(dts_token[0]), .DTSFetchIndex_i(dts_index[0]),
    .WrDTSChipSelect_i(controller_dts_write[1]), .WrDTSWrite_i(controller_dts_write[1]),
    .WrDTSWriteData_i(dts_data[1]), .WrDTSWaitRequest_o(controller_dts_wait[1]),
    .WrDTSFetchEpoch_i(dts_epoch[1]), .WrDTSFetchToken_i(dts_token[1]), .WrDTSFetchIndex_i(dts_index[1]),
    .WriteDescValid_o(copy_valid), .WriteDescData_o(copy_data), .WriteDescReady_i(copy_ready),
    .FetchEndValid_i(end_valid && allow_end), .FetchEndReady_o(consumer_end_ready),
    .FetchEndEpoch_i(end_epoch), .FetchEndToken_i(end_token), .FetchEndError_i(end_error),
    // Raw transport has no cancellation/fence contract. Abort control goes to
    // the native mover; its retained debt decides whether End can occur.
    .FetchAbortValid_i(1'b0), .FetchAbortReady_o(), .FetchAbortEpoch_i(32'd0), .FetchAbortToken_i(20'd0),
    .FetchIssueValid_o(fetch_issue_valid), .FetchIssueData_o(fetch_issue_data),
    .FetchIssueFirstId_o(fetch_issue_first), .FetchFault_o(fetch_fault),
    .FetchFaultReason_o(fetch_fault_reason), .FetchFaultEpoch_o(fetch_fault_epoch),
    .FetchFaultToken_o(fetch_fault_token), .FetchFaultIndex_o(fetch_fault_index),
    .FetchLocalErrorValid_o(local_valid), .FetchLocalErrorReady_i(local_ready),
    .FetchLocalErrorEpoch_o(local_epoch), .FetchLocalErrorToken_o(local_token),
    .FetchLocalErrorReason_o(local_reason), .FetchLocalErrorCount_o(local_count),
    .FetchStatusValid_o(fetch_valid), .FetchStatusData_o(fetch_word), .FetchStatusReady_o(fetch_ready),
    .StatusDiagnosticValid_o(diagnostic_valid), .StatusDiagnosticReady_i(diag_ready),
    .StatusDiagnosticData_o(diagnostic_word), .StatusProtocolFault_o(controller_fault),
    .StatusProtocolFaultWord_o(controller_fault_word)
  );

  // This is the real write controller and native FIFO. The fixture samples
  // its DmaTx ready/valid output, not the read controller's internal copier.
  altpcie_dynamic_control_write_v4 #(.READ_CONTROL(0), .DMA_WIDTH(256)) write_controller (
    .Clk_i(clk), .Rstn_i(rstn), .MsiInterface_i(82'b0),
    .DCSChipSelect_i(dcs_cs[1]), .DCSWrite_i(dcs_write[1]), .DCSAddress_i(dcs_address[1]),
    .DCSWriteData_i(dcs_wdata[1]), .DCSByteEnable_i(dcs_be[1]), .DCSRead_i(dcs_read[1]),
    .DCSReadData_o(dcs_rdata[1]), .DCSWaitRequest_o(dcs_wait[1]),
    .DCMAddress_o(dcm_address[1]), .DCMWrite_o(dcm_write[1]), .DCMWriteData_o(dcm_data[1]),
    .DCMRead_o(), .DCMByteEnable_o(dcm_be[1]), .DCMWaitRequest_i(dcm_wait[1]),
    .DCMReadData_i(32'b0), .DCMReadDataValid_i(1'b0),
    .DTSChipSelect_i(copy_valid), .DTSWrite_i(copy_valid), .DTSBurstCount_i(5'd1), .DTSAddress_i(8'd0),
    .DTSWriteData_i({96'b0,copy_data}), .DTSWaitRequest_o(copy_wait),
    .DmaTxData_o(write_data), .DmaTxValid_o(write_valid), .DmaTxReady_i(write_ready),
    .DmaRxData_i(32'b0), .DmaRxValid_i(1'b0),
    .WrDescTxData_o(forward_data), .WrDescTxReq_o(forward_req), .WrDescTxAck_i(forward_ack),
    .WrDescTxAck_o(), .WrDescTxReq_i(1'b0), .WrDescTxData_i(160'b0),
    .WrDescFirstId_i(8'b0), .WrDescFirstId_o(forward_first)
  );

  // These assertions observe real boundaries. They add no ownership state.
  // synthesis translate_off
  assert property (@(posedge clk) disable iff(!rstn)
    (read_tx_valid && read_tx_ready) == (descriptor_valid && descriptor_ready));
  assert property (@(posedge clk) disable iff(!rstn)
    fetch_issue_valid == (read_tx_valid && read_tx_ready && read_tx_data[153]));
  assert property (@(posedge clk) disable iff(!rstn)
    bind_valid |-> fetch_issue_valid && bind_desc==read_tx_data);
  assert property (@(posedge clk) disable iff(!rstn)
    (engine_status_valid && engine_status_ready) ==
      (engine_status_valid && allow_status && controller_status_ready));
  assert property (@(posedge clk) disable iff(!rstn)
    (end_valid && end_ready) == (end_valid && allow_end && consumer_end_ready));
  assert property (@(posedge clk) disable iff(!rstn)
    route_accept == ((payload_write && !payload_wait) || (|(dts_write & ~dts_wait))));
  for(genvar p=0;p<2;p++) begin : table_handshake
    assert property (@(posedge clk) disable iff(!rstn)
      (dts_write[p] && !dts_wait[p]) ==
        (controller_dts_write[p] && !controller_dts_wait[p]));
  end
  // synthesis translate_on
endmodule
`default_nettype wire
