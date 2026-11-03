// SPDX-License-Identifier: BSD-3-Clause
assign v2_head_slot = desc_head[RDDMA_RXDATA_WIDTH +: 4];
assign v2_head_drop = v2_halted[v2_head_slot];
assign v2_start = rd_pop_desc_state && !v2_head_drop;
assign v2_close = v2_current_valid && rd_dma_state != RD_IDLE &&
rd_dma_nxt_state == RD_IDLE;
assign v2_control_load = RdDMACntrlLoad_i && RdDMACntrlReady_o;
assign v2_master_error = v2_current_valid && !MasterEnable_i;
assign v2_stop_issue = ContractFault_o || v2_external_fault ||
(v2_current_valid && (v2_halted[v2_current_slot] || !MasterEnable_i ||
(v2_control_load && (RdDMACntrlData_i[2] || RdDMACntrlData_i[3]))));
assign v2_bad_header = !rx_fifo_empty && rx_sop &&
(!is_cpl_wd || cpl_tag >= 16 ||
!v2_tag_live[cpl_tag[3:0]] || v2_last_header[cpl_tag[3:0]] ||
rx_dwlen == 0 || rx_dwlen > remain_dw);
assign v2_external_fault = v2_guard_fault || v2_bad_header;
always_ff @(posedge Clk_i or negedge Rstn_i) begin
if (!Rstn_i) begin
v2_current_slot <= '0; v2_current_valid <= 1'b0;
v2_cpl_slot <= '0; v2_cmd_slot_pipe <= '0; v2_write_slot <= '0;
v2_tag_live <= '0; v2_last_header <= '0;
v2_guard_fault <= 1'b0;
for (int v2_i = 0; v2_i < 16; v2_i++) v2_tag_owner[v2_i] <= '0;
end else begin
if (v2_start) begin
v2_current_slot <= v2_head_slot;
v2_current_valid <= 1'b1;
end else if (v2_close) v2_current_valid <= 1'b0;
if (rd_header_state) begin
v2_tag_owner[rd_tag_reg[3:0]] <= v2_current_slot;
v2_tag_live[rd_tag_reg[3:0]] <= 1'b1;
v2_last_header[rd_tag_reg[3:0]] <= 1'b0;
end
if (latch_header) begin
v2_cpl_slot <= v2_tag_owner[cpl_tag[3:0]];
if (last_cpl) v2_last_header[cpl_tag[3:0]] <= 1'b1;
end
if (tag_release) v2_tag_live[released_tag] <= 1'b0;
v2_cmd_slot_pipe <= v2_cpl_slot;
if (avmmwr_cmd_fifo_rdreq) v2_write_slot <= avmmwr_cmd_q[74:71];
if ((tag_release_queuing && tag_queu_count == 4 && !tag_queu_rdreq) ||
(latch_header_reg2 && avmmwr_cmd_count == 16 && !avmmwr_cmd_fifo_rdreq) ||
(rdcpl_write_state_reg && avmmwr_fifo_usedw == 511 && !avmmwr_data_fifo_rdreq) ||
(desc_fifo_wrreq && desc_fifo_count >= 6) ||
(rd_header_state && !v2_current_valid)) v2_guard_fault <= 1'b1;
end
end
dma_owner_v2 v2_owners (
.clk(Clk_i), .rstn(Rstn_i),
.descriptor_valid(RdDmaRxValid_i), .descriptor_ready(v2_desc_ready),
.descriptor_room(desc_fifo_count < 3),
.descriptor_id(RdDmaRxData_i[153:146]), .descriptor_slot(v2_alloc_slot),
.start_valid(v2_start), .start_slot(v2_head_slot),
.current_valid(v2_current_valid), .current_slot(v2_current_slot),
.issue_valid(rd_header_state), .issue_slot(v2_current_slot),
.return_valid(tag_release), .return_slot(v2_tag_owner[released_tag]),
.command_valid(latch_header), .command_slot(v2_tag_owner[cpl_tag[3:0]]),
.retire_valid(end_avmm_cycle), .retire_slot(v2_write_slot),
.close_valid(v2_close), .close_slot(v2_current_slot),
.master_error(v2_master_error),
.control_valid(RdDMACntrlLoad_i), .control_data(RdDMACntrlData_i[3:0]),
.control_ready(RdDMACntrlReady_o), .halted(v2_halted),
.external_fault(v2_external_fault), .contract_fault(ContractFault_o),
.status_valid(RdDmaTxValid_o), .status_ready(RdDmaTxReady_i),
.status_word(RdDmaTxData_o),
.ack_valid(RdDmaAckValid_i), .ack_word(RdDmaAckData_i)
);
// synthesis translate_off
initial begin
if (DMA_WIDTH != 256 || DMA_BE_WIDTH != 32 || DMA_BRST_CNT_W != 5 ||
NUM_TAG != 16 || NUM_TAG_WIDTH != 4 || EXTENDED_TAG_ENABLE != 0 ||
dma_use_scfifo_ext != 0 || RDDMA_RXDATA_WIDTH != 160 ||
RXFIFO_DATA_WIDTH != 266 || TX_FIFO_WIDTH != 260)
$fatal(1, "candidate-v2 supports 256-bit, 16 nonextended tags, native scfifo only");
end
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
avmmwr_cmd_count <= 16 && tag_queu_count <= 4 && desc_fifo_count <= 6);
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
RdDmaWrite_o && RdDmaWaitRequest_i |=> RdDmaWrite_o &&
$stable({RdDmaAddress_o,RdDmaWriteData_o,RdDmaWriteEnable_o,RdDmaBurstCount_o}));
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
latch_header |-> v2_tag_live[cpl_tag[3:0]] && !v2_last_header[cpl_tag[3:0]]);
// synthesis translate_on
