// SPDX-License-Identifier: BSD-3-Clause
// Included ONLY in the SHA-bound write-controller derivative, READ_CONTROL=0.
// Native status has no ready. Reserve capacity when the data descriptor fires,
// before any payload read can complete; completion merely changes its owner.
// This queue replaces the original uncredited 128-entry ep_last FIFO and its
// live-base/live-MSI DCM tail. It retains the original DCM ABI: DWORD 1 at
// header_base + 4*ID[6:0], followed by the programmed MSI write when requested.
// Neither native status nor a DCM handshake establishes PCIe host visibility.

localparam int C1_CAPACITY = 128;
typedef struct packed {
  logic [7:0] id;
  logic [63:0] status_address;
  logic [63:0] msi_address;
  logic [15:0] msi_data;
  logic msi_enable;
  logic report_status;
  logic endpoint;
} c1_entry_t;
c1_entry_t c1_entries [0:C1_CAPACITY-1];
c1_entry_t c1_head_entry, c1_status_entry;
logic [6:0] c1_issue_ptr, c1_status_ptr, c1_retire_ptr;
logic [8:0] c1_reserved, c1_pending, c1_completed;
logic [127:0] c1_id_live, c1_endpoint_live;
// c1_can_issue/config_busy/doorbell_block/fault are declared before the v4 TX
// include by the hash-bound builder, because that include consumes these gates.
logic [31:0] c1_fault_data;
logic [7:0] c1_fault_expected_id;
wire [7:0] c1_issue_id = DmaTxData_o[153:146];
wire c1_new_doorbell = ep_last_pntr_not_from_pending_wen || pending_desc_id_wen;
wire c1_issue_endpoint = pending_desc_update_array[c1_issue_id[6:0]] ||
  (c1_new_doorbell && DCSWriteData_i[7:0] == c1_issue_id);
wire c1_status_bad = dma_status_valid_reg &&
  (c1_pending == 0 || dma_status_reg != {23'b0, 1'b1, c1_status_entry.id});
wire c1_status_fire = dma_status_valid_reg && !c1_fault && !c1_status_bad;
wire c1_head_needs_msi = c1_head_entry.endpoint && c1_head_entry.msi_enable;
wire c1_skip = dcm_state == DCM_IDLE && c1_completed != 0 &&
               !c1_head_entry.report_status;
wire c1_status_write = dcm_state == DCM_WR && !DCMWaitRequest_i;
wire c1_msi_write = dcm_state == DCM_MSI_WR && !DCMWaitRequest_i;
wire c1_retire = c1_skip || (c1_status_write && !c1_head_needs_msi) || c1_msi_write;

assign c1_head_entry = c1_entries[c1_retire_ptr];
assign c1_status_entry = c1_entries[c1_status_ptr];
// No lookahead reuse of a retiring slot: at full, admission resumes next edge.
// A held offer's credit cannot be stolen: this controller is the sole issuer.
// IDs 128..255 are fetch IDs, not admissible data-descriptor status slots.
assign c1_can_issue = !c1_fault && c1_reserved < C1_CAPACITY &&
                      !c1_issue_id[7] && !c1_id_live[c1_issue_id[6:0]];
assign c1_config_busy = c1_fault || c1_reserved != 0 || !dt_fifo_empty ||
  dt_fifo_count != 0 || dma_tx_state != DMA_TX_IDLE || v4_config_busy ||
  (DTSChipSelect_i && DTSWrite_i) || (|c1_endpoint_live);
// A doorbell denotes an occurrence, not an unbounded per-ID counter. Backpressure
// a reused live endpoint, or a late doorbell for an already admitted occurrence.
// Distinct queued doorbells remain legal. The accepted copier boundary must arm
// each endpoint before its intended occurrence is admitted, without an older
// unadmitted occurrence of that same ID remaining in the copier/DTS stream.
// Fully overlapping table generations need copier generation metadata; the
// native status ABI provides only an ID, so this include does not invent it.
// Hold through the cycle after the boundary flag clears as well: the original
// automatic pending-doorbell move has lower priority than an external write.
// Accepting another write in that cycle would discard the saved occurrence.
assign c1_doorbell_block = c1_fault || pending_desc_id_stored || DCSWriteData_i[7] ||
  c1_endpoint_live[DCSWriteData_i[6:0]] || c1_id_live[DCSWriteData_i[6:0]];

always_ff @(posedge Clk_i or negedge Rstn_i) begin
  if (!Rstn_i) begin
    c1_issue_ptr <= 0; c1_status_ptr <= 0; c1_retire_ptr <= 0;
    c1_reserved <= 0; c1_pending <= 0; c1_completed <= 0;
    c1_id_live <= 0; c1_endpoint_live <= 0; pending_desc_update_array <= 0;
    c1_fault <= 0; c1_fault_data <= 0; c1_fault_expected_id <= 0;
  end else begin
    // Keep the first untrusted/failing status verbatim. Never map its ID to a
    // success slot or replace its completion bit. Pending reservations remain
    // owned until external containment/reset. Older checked completions may
    // still drain, so an already held DCM request is never withdrawn on fault.
    if (c1_status_bad && !c1_fault) begin
      c1_fault <= 1;
      c1_fault_data <= dma_status_reg;
      c1_fault_expected_id <= c1_pending != 0 ? c1_status_entry.id : 8'b0;
    end
    case ({v4_tx_fire, c1_retire})
      2'b10: c1_reserved <= c1_reserved + 9'd1;
      2'b01: c1_reserved <= c1_reserved - 9'd1;
      default: ;
    endcase
    case ({v4_tx_fire, c1_status_fire})
      2'b10: c1_pending <= c1_pending + 9'd1;
      2'b01: c1_pending <= c1_pending - 9'd1;
      default: ;
    endcase
    case ({c1_status_fire, c1_retire})
      2'b10: c1_completed <= c1_completed + 9'd1;
      2'b01: c1_completed <= c1_completed - 9'd1;
      default: ;
    endcase
    if (c1_retire) begin
      c1_retire_ptr <= c1_retire_ptr + 7'd1;
      c1_id_live[c1_head_entry.id[6:0]] <= 0;
      if (c1_head_entry.endpoint) c1_endpoint_live[c1_head_entry.id[6:0]] <= 0;
    end
    if (c1_new_doorbell) begin
      pending_desc_update_array[DCSWriteData_i[6:0]] <= 1;
      c1_endpoint_live[DCSWriteData_i[6:0]] <= 1;
    end
    if (v4_tx_fire) begin
      c1_entries[c1_issue_ptr].id <= c1_issue_id;
      c1_entries[c1_issue_ptr].status_address <=
        dt_header_base + {55'b0, c1_issue_id[6:0], 2'b00};
      c1_entries[c1_issue_ptr].msi_address <= MsiInterface_i[63:0];
      c1_entries[c1_issue_ptr].msi_data <= MsiInterface_i[79:64];
      c1_entries[c1_issue_ptr].msi_enable <= MsiInterface_i[80];
      c1_entries[c1_issue_ptr].report_status <= ctrl_reg[0] || c1_issue_endpoint;
      c1_entries[c1_issue_ptr].endpoint <= c1_issue_endpoint;
      c1_issue_ptr <= c1_issue_ptr + 7'd1;
      c1_id_live[c1_issue_id[6:0]] <= 1;
      if (c1_issue_endpoint) pending_desc_update_array[c1_issue_id[6:0]] <= 0;
    end
    if (c1_status_fire) c1_status_ptr <= c1_status_ptr + 7'd1;
  end
end

// The original one-hot DCM states and bus contract remain. The head owns all
// address/data/MSI fields throughout both phases, including arbitrary stalls.
always_ff @(posedge Clk_i or negedge Rstn_i) begin
  if (!Rstn_i) dcm_state <= DCM_IDLE;
  else dcm_state <= dcm_nxt_state;
end
always_comb begin
  dcm_nxt_state = dcm_state;
  case (dcm_state)
    DCM_IDLE:
      if (c1_completed != 0 && c1_head_entry.report_status) dcm_nxt_state = DCM_WR;
    DCM_WR:
      if (!DCMWaitRequest_i)
        dcm_nxt_state = c1_head_needs_msi ? DCM_MSI_WR : DCM_IDLE;
    DCM_MSI_WR:
      if (!DCMWaitRequest_i) dcm_nxt_state = DCM_IDLE;
    default: dcm_nxt_state = DCM_IDLE;
  endcase
end
assign DCMWrite_o = dcm_state[1] || dcm_state[2];
assign DCMRead_o = 1'b0;
assign DCMWriteData_o = dcm_state[1] ? 32'h1 : {16'b0, c1_head_entry.msi_data};
assign DCMByteEnable_o = 4'hf;
assign DCMAddress_o = dcm_state[1] ? c1_head_entry.status_address : c1_head_entry.msi_address;

// Diagnostic aliases preserve the *meaning* of bit 8: endpoint/MSI marker.
// It is never tested as the incoming native completion bit.
assign ep_last_to_rc = {c1_head_entry.endpoint, c1_head_entry.id};
assign ep_last_data = {c1_status_entry.endpoint, c1_status_entry.id};
assign ep_last_fifo_count = c1_completed[7:0];
assign ep_last_fifo_wrreq = c1_status_fire;
assign ep_last_fifo_rdreq = c1_retire;
assign ep_last_from_dma = dma_status_reg[7:0];
assign RetireFault_o = c1_fault;
assign RetireFaultData_o = c1_fault_data;
assign RetireExpectedId_o = c1_fault_expected_id;
assign RetireBusy_o = c1_reserved != 0;

// synthesis translate_off
initial begin
  if (READ_CONTROL != 0 || DMA_WIDTH != 256)
    $fatal(1, "C1_CONTROLLER_CONFIGURATION");
end
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  c1_reserved == ({1'b0,c1_pending} + {1'b0,c1_completed}) &&
  c1_reserved <= C1_CAPACITY) else $fatal(1, "C1_RESERVATION_ACCOUNTING");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  7'(c1_issue_ptr-c1_retire_ptr)==c1_reserved[6:0] &&
  7'(c1_status_ptr-c1_retire_ptr)==c1_completed[6:0] &&
  7'(c1_issue_ptr-c1_status_ptr)==c1_pending[6:0])
  else $fatal(1, "C1_RING_POINTER_ACCOUNTING");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  $countones(c1_id_live)==c1_reserved &&
  (pending_desc_update_array & ~c1_endpoint_live)==128'b0)
  else $fatal(1, "C1_ID_CUSTODY");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  $countones(c1_id_live) == int'(c1_reserved) &&
  (pending_desc_update_array & ~c1_endpoint_live) == 128'b0)
  else $fatal(1, "C1_ID_GENERATION_ACCOUNTING");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  v4_tx_fire |-> c1_can_issue && !c1_issue_id[7])
  else $fatal(1, "C1_UNRESERVED_ADMISSION");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  c1_status_fire |-> c1_pending != 0 && c1_completed < C1_CAPACITY &&
    c1_id_live[c1_status_entry.id[6:0]])
  else $fatal(1, "C1_STATUS_CAPACITY");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  c1_retire |-> c1_completed != 0 && c1_reserved != 0)
  else $fatal(1, "C1_UNOWNED_RETIREMENT");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  DCMWrite_o |-> c1_completed != 0)
  else $fatal(1, "C1_WRITE_WITHOUT_CHECKED_COMPLETION");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  DCMWrite_o && DCMWaitRequest_i |=> DCMWrite_o &&
    $stable({DCMAddress_o, DCMWriteData_o, DCMByteEnable_o, DCMRead_o}))
  else $fatal(1, "C1_DCM_HOLD");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  dma_status_valid_reg |-> !$isunknown(dma_status_reg))
  else $fatal(1, "C1_UNKNOWN_NATIVE_STATUS");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  c1_fault |=> c1_fault && $stable({c1_fault_data,c1_fault_expected_id}))
  else $fatal(1, "C1_FAULT_NOT_RETAINED");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  c1_fault |-> !v4_tx_fire)
  else $fatal(1, "C1_FAULT_ADMISSION");
assert property (@(posedge Clk_i) disable iff (!Rstn_i)
  c1_new_doorbell |-> !c1_doorbell_block)
  else $fatal(1, "C1_DOORBELL_GENERATION_COLLISION");
// synthesis translate_on
