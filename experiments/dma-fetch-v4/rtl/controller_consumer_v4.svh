// SPDX-License-Identifier: BSD-3-Clause
logic v4_payload_valid, v4_payload_ready, v4_pick_write, v4_turn;
logic v4_emit_valid, v4_emit_ready, v4_emit_write;
logic [159:0] v4_emit_data;
logic v4_status_ready, v4_diag_valid;
logic [31:0] v4_diag_word;
logic v4_sink_fault;
logic [31:0] v4_sink_fault_word;
logic v4_sink_diag_valid;
logic [31:0] v4_sink_diag_word;
// One fair physical RAM write port. Tokens remain attached to stalled beats.
assign v4_pick_write = WrDTSChipSelect_i && WrDTSWrite_i &&
  (!(DTSChipSelect_i && DTSWrite_i) || v4_turn);
assign v4_payload_valid = v4_pick_write ?
  WrDTSChipSelect_i && WrDTSWrite_i : DTSChipSelect_i && DTSWrite_i;
assign DTSWaitRequest_o = v4_pick_write || !v4_payload_ready;
assign WrDTSWaitRequest_o = !v4_pick_write || !v4_payload_ready;
always_ff @(posedge Clk_i or negedge Rstn_i)
  if (!Rstn_i) v4_turn<=0;
  else if (v4_payload_valid && v4_payload_ready) v4_turn<=!v4_pick_write;
assign dt_fifo_ok = dt_fifo_count<=250;
assign dt_fifo_data_in = v4_emit_data;
assign dt_fifo_wrreq_reg = v4_emit_valid && !v4_emit_write && dt_fifo_ok;
assign dt_fifo_wrreq_reg1 = 1'b0;
assign WriteDescValid_o = v4_emit_valid && v4_emit_write;
assign WriteDescData_o = v4_emit_data;
assign v4_emit_ready = v4_emit_write ? WriteDescReady_i : dt_fifo_ok;
assign FetchIssueValid_o = v4_tx_fire && v4_is_fetch;
assign FetchIssueData_o = DmaTxData_o;
assign FetchIssueFirstId_o = dma_tx_state==DMA_TX_DT_SEND ? v4_first : v4_forward_first;
assign FetchStatusReady_o = v4_status_ready;
assign v4_tx_fault = FetchFault_o;
assign StatusProtocolFault_o = v4_sink_fault || FetchFault_o;
assign StatusProtocolFaultWord_o = v4_sink_fault ? v4_sink_fault_word :
  {4'h0,FetchFaultReason_o,FetchFaultToken_o};
dma_fetch_commit_v4 fetch_consumer (
  .clk(Clk_i), .rstn(Rstn_i), .enable(FetchEnable_i), .epoch(FetchEpoch_i),
  .issue_offer(v4_issue_offer),
  .issue_valid(v4_raw_valid && v4_is_fetch && DmaTxReady_i),
  .issue_ready(v4_issue_ready), .issue_desc(v4_issue_desc),
  .issue_first(v4_issue_first),
  .bind_valid(FetchBindValid_i), .bind_desc(FetchBindData_i), .bind_token(FetchBindToken_i),
  .payload_valid(v4_payload_valid), .payload_ready(v4_payload_ready),
  .payload_write_table(v4_pick_write),
  .payload_epoch(v4_pick_write ? WrDTSFetchEpoch_i : DTSFetchEpoch_i),
  .payload_token(v4_pick_write ? WrDTSFetchToken_i : DTSFetchToken_i),
  .payload_index(v4_pick_write ? WrDTSFetchIndex_i : DTSFetchIndex_i),
  .payload_data(v4_pick_write ? WrDTSWriteData_i[159:0] : DTSWriteData_i[159:0]),
  .end_valid(FetchEndValid_i), .end_ready(FetchEndReady_o),
  .end_epoch(FetchEndEpoch_i), .end_token(FetchEndToken_i), .end_error(FetchEndError_i),
  .abort_valid(FetchAbortValid_i), .abort_ready(FetchAbortReady_o),
  .abort_epoch(FetchAbortEpoch_i), .abort_token(FetchAbortToken_i),
  .status_valid(v3_fetch_valid || v4_sink_diag_valid), .status_ready(v4_status_ready),
  .status_word(v3_fetch_valid ? v3_fetch_word : v4_sink_diag_word),
  .ack_valid(DmaAckValid_o), .ack_consumed(DmaAckConsumed_i), .ack_word(DmaAckData_o),
  .emit_valid(v4_emit_valid), .emit_ready(v4_emit_ready),
  .emit_write_table(v4_emit_write), .emit_data(v4_emit_data),
  .diagnostic_valid(StatusDiagnosticValid_o), .diagnostic_ready(StatusDiagnosticReady_i),
  .diagnostic_word(StatusDiagnosticData_o), .fault(FetchFault_o),
  .fault_reason(FetchFaultReason_o), .fault_epoch(FetchFaultEpoch_o),
  .fault_token(FetchFaultToken_o), .fault_index(FetchFaultIndex_o),
  .local_error_valid(FetchLocalErrorValid_o), .local_error_ready(FetchLocalErrorReady_i),
  .local_error_epoch(FetchLocalErrorEpoch_o), .local_error_token(FetchLocalErrorToken_o),
  .local_error_reason(FetchLocalErrorReason_o), .local_error_count(FetchLocalErrorCount_o)
);
// The emitter handshake IS the sampled physical scfifo write, or the sampled
// write-controller FIFO write. No delayed staging observation is an ACK.
// synthesis translate_off
assert property (@(posedge Clk_i) disable iff(!Rstn_i)
  dt_fifo_wrreq_reg |-> dt_fifo_count<=250 && v4_emit_valid && !v4_emit_write);
assert property (@(posedge Clk_i) disable iff(!Rstn_i) dt_fifo_count<=251);
// synthesis translate_on
