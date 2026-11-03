// SPDX-License-Identifier: BSD-3-Clause
// Included inside both source-checked controller derivatives.
logic [159:0] v4_fetch_snapshot, v4_forward_snapshot;
logic [7:0] v4_last, v4_count, v4_table_last, v4_first, v4_forward_first;
logic [63:0] v4_table_base;
logic v4_write_request, v4_capture, v4_tx_fire, v4_fetch_fire;
logic v4_issue_ready, v4_raw_valid, v4_is_fetch, v4_config_busy, v4_tx_fault;
logic [159:0] v4_issue_desc;
logic [7:0] v4_issue_first;
logic v4_issue_offer, v4_query_write, v4_prefer_write;
assign v4_config_busy = fetch_desc_pending_sreg || v4_write_request ||
                       pending_desc_id_stored ||
                       dma_tx_state==DMA_TX_DT_SEND || dma_tx_state==DMA_WRDESC_SEND;
assign v4_query_write = WrDescTxReq_i &&
                       (!fetch_desc_pending_sreg || v4_prefer_write);
assign v4_capture = READ_CONTROL==1 ?
  (dma_tx_state==DMA_TX_IDLE && !v4_query_write && fetch_desc_pending_sreg && v4_issue_ready) :
  (!v4_write_request && fetch_desc_pending_sreg);
assign v4_raw_valid = dma_tx_state==DMA_TX_PROGRAM ||
  (READ_CONTROL==1 && (dma_tx_state==DMA_TX_DT_SEND || dma_tx_state==DMA_WRDESC_SEND));
assign v4_is_fetch = dma_tx_state==DMA_TX_DT_SEND || dma_tx_state==DMA_WRDESC_SEND;
// Query credit BEFORE entering a fetch SEND state. A blocked fetch must not
// prevent the data FIFO from draining the committed banks that provide credit.
// This controller is the sole issuer, so an available credit cannot be stolen
// between snapshot selection and its eventual ready/valid acceptance.
assign v4_issue_offer = READ_CONTROL==1 &&
  ((dma_tx_state==DMA_TX_IDLE && (WrDescTxReq_i || fetch_desc_pending_sreg)) ||
   (v4_raw_valid && v4_is_fetch));
assign v4_issue_desc = dma_tx_state==DMA_TX_IDLE ?
  (v4_query_write ? WrDescTxData_i : dt_tx_data) : DmaTxData_o;
assign v4_issue_first = dma_tx_state==DMA_TX_IDLE ?
  (v4_query_write ? WrDescFirstId_i : prev_desc_id_reg+8'd1) :
  (dma_tx_state==DMA_TX_DT_SEND ? v4_first : v4_forward_first);
assign DmaTxValid_o = Rstn_i && v4_raw_valid &&
  (READ_CONTROL==0 || !v4_is_fetch || v4_issue_ready);
assign DmaTxData_o = dma_tx_state==DMA_TX_DT_SEND ? v4_fetch_snapshot :
  dma_tx_state==DMA_WRDESC_SEND ? v4_forward_snapshot : dt_fifo_dataq;
assign v4_tx_fire = DmaTxValid_o && DmaTxReady_i;
assign desc_fetch_send = READ_CONTROL==1 && dma_tx_state==DMA_TX_DT_SEND && v4_tx_fire;
assign v4_fetch_fire = READ_CONTROL==1 ? desc_fetch_send :
                       (v4_write_request && WrDescTxAck_i);
assign WrDescTxReq_o = READ_CONTROL==0 && v4_write_request;
assign WrDescTxData_o = READ_CONTROL==0 ? v4_fetch_snapshot : 160'b0;
assign WrDescFirstId_o = READ_CONTROL==0 ? v4_first : 8'b0;
assign WrDescTxAck_o = READ_CONTROL==1 && dma_tx_state==DMA_WRDESC_SEND && v4_tx_fire;
assign dt_fifo_rdreq = dma_tx_state==DMA_TX_FIFO_RD;
always_ff @(posedge Clk_i or negedge Rstn_i) begin
  if (!Rstn_i) begin
    dma_tx_state<=DMA_TX_IDLE; v4_write_request<=0; v4_prefer_write<=1;
    v4_fetch_snapshot<=0; v4_forward_snapshot<=0; v4_last<=0; v4_count<=0;
    v4_table_last<=0; v4_table_base<=0; v4_first<=0; v4_forward_first<=0;
  end else begin
    // Rotate a blocked query too: a retained write-table ID cannot indefinitely
    // hide an otherwise admissible local read-table request (and conversely).
    if (READ_CONTROL==1 && dma_tx_state==DMA_TX_IDLE &&
        WrDescTxReq_i && fetch_desc_pending_sreg)
      v4_prefer_write<=!v4_query_write;
    if (v4_capture) begin
      v4_fetch_snapshot<=dt_tx_data;
      v4_last<=current_desc_id; v4_count<=sent_dt_size;
      v4_table_last<=table_id_size_reg[7:0]; v4_table_base<=dt_desc_base;
      v4_first<=prev_desc_id_reg+8'd1;
      if (READ_CONTROL==0) v4_write_request<=1;
    end
    if (READ_CONTROL==0 && v4_fetch_fire) v4_write_request<=0;
    case (dma_tx_state)
      DMA_TX_IDLE: begin
        if (READ_CONTROL==1 && v4_query_write && v4_issue_ready) begin
          v4_forward_snapshot<=WrDescTxData_i;
          v4_forward_first<=WrDescFirstId_i;
          dma_tx_state<=DMA_WRDESC_SEND;
        end else if (READ_CONTROL==1 && !v4_query_write &&
                     fetch_desc_pending_sreg && v4_issue_ready)
          dma_tx_state<=DMA_TX_DT_SEND;
        else if (!dt_fifo_empty) dma_tx_state<=DMA_TX_FIFO_RD;
      end
      DMA_TX_FIFO_RD: dma_tx_state<=DMA_TX_WAIT;
      DMA_TX_WAIT: dma_tx_state<=DMA_TX_PROGRAM;
      DMA_TX_PROGRAM, DMA_TX_DT_SEND, DMA_WRDESC_SEND:
        if (v4_tx_fire) dma_tx_state<=DMA_TX_IDLE;
      default: dma_tx_state<=DMA_TX_IDLE;
    endcase
  end
end
// A snapshot consumes a doorbell. A simultaneous/new doorbell remains pending.
always_ff @(posedge Clk_i or negedge Rstn_i) begin
  if (!Rstn_i) fetch_desc_pending_sreg<=0;
  else if (ep_last_pntr_wen) fetch_desc_pending_sreg<=1;
  else if (v4_capture) fetch_desc_pending_sreg<=0;
end
// synthesis translate_off
// A retained fatal contract fault cancels unaccepted read-fetch offers. This
// fail-stop boundary requires external containment/reset; it is not acceptance.
assert property (@(posedge Clk_i) disable iff(!Rstn_i || v4_tx_fault)
  DmaTxValid_o && !DmaTxReady_i |=> DmaTxValid_o && $stable(DmaTxData_o));
assert property (@(posedge Clk_i) disable iff(!Rstn_i)
  WrDescTxReq_o && !WrDescTxAck_i |=> WrDescTxReq_o &&
    $stable({WrDescTxData_o,WrDescFirstId_o}));
assert property (@(posedge Clk_i) disable iff(!Rstn_i)
  desc_fetch_send |-> DmaTxValid_o && DmaTxReady_i);
assert property (@(posedge Clk_i) disable iff(!Rstn_i || v4_tx_fault)
  READ_CONTROL==1 && dma_tx_state==DMA_TX_IDLE &&
  (WrDescTxReq_i || fetch_desc_pending_sreg) && !v4_issue_ready &&
  !dt_fifo_empty |=> dma_tx_state==DMA_TX_FIFO_RD);
assert property (@(posedge Clk_i) disable iff(!Rstn_i || v4_tx_fault)
  READ_CONTROL==1 &&
  ($rose(dma_tx_state==DMA_TX_DT_SEND) || $rose(dma_tx_state==DMA_WRDESC_SEND)) |->
    $past(dma_tx_state==DMA_TX_IDLE && v4_issue_ready));
// synthesis translate_on
