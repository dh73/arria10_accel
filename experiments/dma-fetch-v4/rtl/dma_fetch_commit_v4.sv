// SPDX-License-Identifier: BSD-3-Clause
// Complete descriptor-table custody. No descriptor is executable before commit.
// Token = {owner generation[7:0], owner slot[3:0], full descriptor ID[7:0]}.
module dma_fetch_commit_v4 #(
  parameter int BANKS = 16
) (
  input logic clk, rstn, enable,
  input logic [31:0] epoch,
  // A pending query checks request shape without reserving storage.
  input logic issue_offer,
  input logic issue_valid,
  output logic issue_ready,
  input logic [159:0] issue_desc,
  input logic [7:0] issue_first,
  // Actual owner admission may follow the controller TX handshake in a pipe.
  input logic bind_valid,
  input logic [159:0] bind_desc,
  input logic [19:0] bind_token,
  input logic payload_valid,
  output logic payload_ready,
  input logic payload_write_table,
  input logic [31:0] payload_epoch,
  input logic [19:0] payload_token,
  input logic [6:0] payload_index,
  input logic [159:0] payload_data,
  input logic end_valid,
  output logic end_ready,
  input logic [31:0] end_epoch,
  input logic [19:0] end_token,
  input logic end_error,
  input logic abort_valid,
  output logic abort_ready,
  input logic [31:0] abort_epoch,
  input logic [19:0] abort_token,
  input logic status_valid,
  output logic status_ready,
  input logic [31:0] status_word,
  input logic ack_valid, ack_consumed,
  input logic [31:0] ack_word,
  output logic emit_valid,
  input logic emit_ready,
  output logic emit_write_table,
  output logic [159:0] emit_data,
  output logic diagnostic_valid,
  input logic diagnostic_ready,
  output logic [31:0] diagnostic_word,
  // Local transport failures are not synthetic wire-status-v2 completions.
  // Each bank retains one event until accepted; the failed bank stays live.
  output logic local_error_valid,
  input logic local_error_ready,
  output logic [31:0] local_error_epoch,
  output logic [19:0] local_error_token,
  output logic [7:0] local_error_reason, local_error_count,
  output logic fault,
  output logic [7:0] fault_reason,
  output logic [31:0] fault_epoch,
  output logic [19:0] fault_token,
  output logic [7:0] fault_index
);
  import dma_status_v2_pkg::*;
  localparam int BW = BANKS > 1 ? $clog2(BANKS) : 1;
  typedef logic [BW-1:0] bank_t;
  // Fatal reasons 1..9: issue, bind, payload, end, status, abort, epoch,
  // receipt protocol, enable withdrawn while a context remains live.
  logic [BANKS-1:0] live, bound, sealed, poisoned, committed, diag_pending;
  logic [BANKS-1:0] local_pending;
  logic [159:0] issued [BANKS];
  logic [19:0] token [BANKS];
  logic [31:0] bank_epoch [BANKS], diagnostic [BANKS], success_word [BANKS];
  logic [7:0] first_id [BANKS], needed [BANKS], received [BANKS], drained [BANKS];
  logic [127:0] seen [BANKS];
  // Local reasons: 1 producer error, 2 partial clean close, 3 local abort.
  logic [7:0] local_reason [BANKS], local_count [BANKS];
  logic [159:0] table_ram [BANKS][128];
  // 0 awaiting receipt, 1 saw valid/consumed, 2 saw valid low, 3 closed.
  logic [1:0] receipt [BANKS];
  logic [BW-1:0] emit_bank, cursor, diag_bank, local_bank, receipt_bank;
  logic diag_active, local_active, receipt_active;
  integer free_bank, ib, pb, eb, ab, sb, db, lb, rb, pick;
  logic duplicate_id, issue_shape, fire_issue, bind_ok, payload_ok, end_ok;
  logic payload_wait_bind, end_wait_bind, abort_wait_bind, status_wait_bind;
  logic bad_event, bad_payload, bad_end, bad_abort, bad_status, bad_bind, bad_receipt;
  logic [7:0] reason_now, index_now;
  logic [19:0] token_now;
  logic [31:0] epoch_now;
  logic [31:0] session_epoch;
  logic session_valid;
  logic [19:0] status_token;
  assign status_token = {status_word[23:16],status_word[15:12],status_word[7:0]};
  always_comb begin
    free_bank=-1; ib=-1; pb=-1; eb=-1; ab=-1; sb=-1; db=-1; lb=-1; rb=-1;
    duplicate_id=0;
    payload_wait_bind=0; end_wait_bind=0; abort_wait_bind=0; status_wait_bind=0;
    for (int k=0;k<BANKS;k++) begin
      if (!live[k] && free_bank<0) free_bank=k;
      if (live[k]) begin
        duplicate_id |= issued[k][153:146] == issue_desc[153:146];
        if (issued[k] == bind_desc) ib=k;
        if (bound[k] && token[k]==payload_token && bank_epoch[k]==payload_epoch) pb=k;
        if (bound[k] && token[k]==end_token && bank_epoch[k]==end_epoch) eb=k;
        if (bound[k] && token[k]==abort_token && bank_epoch[k]==abort_epoch) ab=k;
        if (bound[k] && token[k]==status_token) sb=k;
        if (!bound[k]) begin
          payload_wait_bind |= bank_epoch[k]==payload_epoch &&
                               issued[k][153:146]==payload_token[7:0];
          end_wait_bind |= bank_epoch[k]==end_epoch &&
                           issued[k][153:146]==end_token[7:0];
          abort_wait_bind |= bank_epoch[k]==abort_epoch &&
                             issued[k][153:146]==abort_token[7:0];
          status_wait_bind |= issued[k][153:146]==status_token[7:0];
        end
        if (committed[k] && success_word[k]==ack_word) rb=k;
      end
      if (diag_pending[k] && db<0) db=k;
      if (local_pending[k] && lb<0) lb=k;
    end
    // 128 descriptors encodes 1024 DW, not zero in the eight-bit count.
    issue_shape = issue_desc[153] && issue_desc[145:139]==0 &&
      issue_desc[130:128]==0 && issue_desc[138:131]>=1 &&
      issue_desc[138:131]<=128 &&
      issue_desc[4:0]==0 && issue_desc[68:64]==0 &&
      ({1'b0,issue_first}+{1'b0,issue_desc[138:131]})<=9'd128;
    issue_ready = rstn && enable && session_valid && epoch==session_epoch &&
                  !fault && free_bank>=0 && !duplicate_id && issue_shape;
    fire_issue = issue_valid && issue_ready;
    if (ib<0 && fire_issue && bind_desc==issue_desc) ib=free_bank;
    bind_ok = ib>=0 && bind_token[19:12]!=0 && bind_token[7] &&
              bind_token[7:0]==bind_desc[153:146];
    if (ib>=0 && live[ib] && bound[ib]) bind_ok=0;
    for (int k=0;k<BANKS;k++)
      if (live[k] && bound[k] && token[k]==bind_token) bind_ok=0;
    payload_ok=0; end_ok=0;
    if (pb>=0) payload_ok = !sealed[pb] && !committed[pb] &&
      payload_write_table==token[pb][6] && payload_index<needed[pb] &&
      !seen[pb][payload_index] && !payload_data[153] &&
      payload_data[153:146]==(first_id[pb]+{1'b0,payload_index});
    if (eb>=0) end_ok = !sealed[eb] && !committed[eb];
    // The owner allocation report can be pipelined. Backpressure a known
    // issued ID until it binds; then require the entire authoritative token.
    bad_payload=payload_valid && !payload_ok && !payload_wait_bind;
    bad_end=end_valid && !end_ok && !end_wait_bind;
    bad_abort=abort_valid && ((ab<0 && !abort_wait_bind) ||
                             (ab>=0 && committed[ab]));
    bad_bind=bind_valid && !bind_ok;
    bad_status=status_valid && (!status_v2_valid(status_word) ||
                               (sb<0 && !status_wait_bind));
    if (status_valid && sb>=0)
      bad_status |= committed[sb] || (status_v2_success(status_word) && poisoned[sb]);
    // Invalid events are retained, never acknowledged as accepted payload.
    // A close has priority over a simultaneous beat; producer must close only
    // after every preceding beat handshake, including other output queues.
    // Independent banks may accept a payload and a close/abort together.
    payload_ready=rstn && enable && !fault && payload_ok &&
                  !(end_valid && eb==pb) && !(abort_valid && ab==pb);
    end_ready=rstn && enable && !fault && end_ok && !(abort_valid && ab==eb);
    if (eb>=0 && (end_error || received[eb]!=needed[eb]) && local_pending[eb])
      end_ready=0;
    abort_ready=rstn && enable && !fault && ab>=0 && !bad_abort;
    if (ab>=0 && local_pending[ab]) abort_ready=0;
    status_ready=0;
    if (rstn && enable && !fault && !bad_status && sb>=0) begin
      if (status_v2_success(status_word))
        status_ready=sealed[sb] && received[sb]==needed[sb] &&
          !poisoned[sb] && !committed[sb] &&
          !(abort_valid && ab==sb) && !(bad_payload && pb==sb) &&
          !(bad_end && eb==sb) && !bad_bind;
      else status_ready=!diag_pending[sb] && !committed[sb];
    end
    diagnostic_valid=rstn && diag_active;
    diagnostic_word=diagnostic[diag_bank];
    local_error_valid=rstn && local_active;
    local_error_epoch=bank_epoch[local_bank];
    local_error_token=token[local_bank];
    local_error_reason=local_reason[local_bank];
    local_error_count=local_count[local_bank];
    // Explicitly observe all four phases. In particular, simultaneous removal
    // of valid and consumed is not a completed return-low observation.
    bad_receipt=0;
    if (receipt_active) begin
      case (receipt[receipt_bank])
        0: bad_receipt=!ack_valid || ack_word!=success_word[receipt_bank];
        1: bad_receipt=ack_valid ?
             (ack_word!=success_word[receipt_bank] || !ack_consumed) : !ack_consumed;
        2: bad_receipt=ack_valid;
        default: bad_receipt=1;
      endcase
    end else if (ack_valid && ack_word[7]) begin
      bad_receipt=rb<0 || !status_v2_success(ack_word);
      if (rb>=0 && receipt[rb]!=0) bad_receipt=1;
    end
    bad_event=0; reason_now=0; token_now=0; epoch_now=epoch; index_now=0;
    if (issue_offer && !issue_shape) begin
      bad_event=1; reason_now=1; token_now={12'b0,issue_desc[153:146]};
    end else if (bad_bind) begin
      bad_event=1; reason_now=2; token_now=bind_token;
    end else if (bad_payload) begin
      bad_event=1; reason_now=3; token_now=payload_token;
      epoch_now=payload_epoch; index_now={1'b0,payload_index};
    end else if (bad_end) begin
      bad_event=1; reason_now=4; token_now=end_token; epoch_now=end_epoch;
    end else if (bad_status) begin
      bad_event=1; reason_now=5; token_now=status_token;
    end else if (bad_abort) begin
      bad_event=1; reason_now=6; token_now=abort_token; epoch_now=abort_epoch;
    end else if (session_valid && epoch!=session_epoch) begin
      bad_event=1; reason_now=7;
    end else if (bad_receipt) begin
      bad_event=1; reason_now=8;
      token_now={ack_word[23:16],ack_word[15:12],ack_word[7:0]};
      if (receipt_active) token_now=token[receipt_bank];
    end else if (session_valid && !enable && (|live)) begin
      bad_event=1; reason_now=9;
    end
    // No same-edge success can escape a newly detected contract fault.
    // Keep issue_ready independent of bind_valid/bad_event: an owner may
    // report admission combinationally from that very issue handshake.
    // A newly accepted issue on a fault edge is still reserved below and
    // quarantined; registered fault prevents subsequent issue and commit.
    if (bad_event) begin
      status_ready=0; end_ready=0; payload_ready=0; abort_ready=0;
    end
  end
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      live<='0; bound<='0; sealed<='0; poisoned<='0; committed<='0;
      diag_pending<='0; fault<=0; fault_reason<=0; fault_epoch<=0;
      local_pending<='0; local_active<=0; local_bank<='0;
      receipt_active<=0; receipt_bank<='0;
      fault_token<=0; fault_index<=0; session_valid<=0; session_epoch<=0;
      emit_valid<=0; emit_data<=0; emit_write_table<=0; emit_bank<='0; cursor<='0;
      diag_active<=0; diag_bank<='0;
      for (int k=0;k<BANKS;k++) begin
        issued[k]<='0; token[k]<='0; bank_epoch[k]<='0; first_id[k]<=0;
        needed[k]<=0; received[k]<=0; drained[k]<=0; seen[k]<='0;
        receipt[k]<=0; diagnostic[k]<=0; success_word[k]<=0;
        local_reason[k]<=0; local_count[k]<=0;
      end
    end else begin
      if (enable && !session_valid) begin session_valid<=1; session_epoch<=epoch; end
      if (bad_event && !fault) begin
        fault<=1; fault_reason<=reason_now; fault_epoch<=epoch_now;
        fault_token<=token_now; fault_index<=index_now;
      end
      if (issue_valid && issue_ready) begin
        live[free_bank]<=1; bound[free_bank]<=0; sealed[free_bank]<=0;
        poisoned[free_bank]<=0; committed[free_bank]<=0; diag_pending[free_bank]<=0;
        local_pending[free_bank]<=0;
        issued[free_bank]<=issue_desc; bank_epoch[free_bank]<=session_epoch;
        first_id[free_bank]<=issue_first; needed[free_bank]<=issue_desc[138:131];
        received[free_bank]<=0; drained[free_bank]<=0; seen[free_bank]<='0;
        receipt[free_bank]<=0; success_word[free_bank]<=0;
      end
      if (bind_valid && bind_ok && !bad_event && !fault) begin
        bound[ib]<=1; token[ib]<=bind_token;
      end
      if (payload_valid && payload_ready) begin
        table_ram[pb][payload_index]<=payload_data;
        seen[pb][payload_index]<=1; received[pb]<=received[pb]+1'b1;
      end
      if (end_valid && end_ready) begin
        sealed[eb]<=1;
        if (end_error || received[eb]!=needed[eb]) begin
          poisoned[eb]<=1;
          local_pending[eb]<=1;
          local_reason[eb]<=end_error ? 8'd1 : 8'd2;
          local_count[eb]<=received[eb];
        end
      end
      if (abort_valid && abort_ready) begin
        poisoned[ab]<=1; local_pending[ab]<=1;
        local_reason[ab]<=3; local_count[ab]<=received[ab];
      end
      if (status_valid && status_ready) begin
        if (status_v2_success(status_word)) begin
          committed[sb]<=1; success_word[sb]<=status_word;
        end else begin
          diagnostic[sb]<=status_word; diag_pending[sb]<=1;
          // Pure PAUSE is nonterminal. All terminal errors retain the bank.
          if ((status_word[27:24] & 4'hd)!=0) poisoned[sb]<=1;
        end
      end
      if (diagnostic_valid && diagnostic_ready) begin
        diag_pending[diag_bank]<=0; diag_active<=0;
      end else if (!diag_active && db>=0) begin
        diag_active<=1; diag_bank<=bank_t'(db);
      end
      if (local_error_valid && local_error_ready) begin
        local_pending[local_bank]<=0; local_active<=0;
      end else if (!local_active && lb>=0) begin
        local_active<=1; local_bank<=bank_t'(lb);
      end
      if (!fault && !bad_event) begin
        if (!receipt_active && ack_valid && ack_word[7] && rb>=0) begin
          receipt_active<=1; receipt_bank<=bank_t'(rb);
          if (ack_consumed) receipt[rb]<=1;
        end else if (receipt_active) begin
          case (receipt[receipt_bank])
            0: if (ack_consumed) receipt[receipt_bank]<=1;
            1: if (!ack_valid) receipt[receipt_bank]<=2;
            2: if (!ack_consumed) begin
              receipt[receipt_bank]<=3; receipt_active<=0;
            end
            default: ;
          endcase
        end
      end
      for (int k=0;k<BANKS;k++) begin
        if (live[k] && committed[k]) begin
          if (!fault && !bad_event && receipt[k]==3 && drained[k]==needed[k] &&
              !diag_pending[k] && !local_pending[k]) begin
            live[k]<=0; bound[k]<=0; committed[k]<=0;
          end
        end
      end
      if (emit_valid) begin
        if (emit_ready) begin
          drained[emit_bank]<=drained[emit_bank]+1'b1;
          emit_valid<=0;
          cursor<=emit_bank==bank_t'(BANKS-1) ? '0 : emit_bank+1'b1;
        end
      end else if (!fault && !bad_event && enable) begin
        pick=-1;
        for (int j=0;j<BANKS;j++)
          if (pick<0 && live[(int'(cursor)+j)%BANKS] &&
              committed[(int'(cursor)+j)%BANKS] &&
              drained[(int'(cursor)+j)%BANKS]<needed[(int'(cursor)+j)%BANKS])
            pick=(int'(cursor)+j)%BANKS;
        if (pick>=0) begin
          emit_bank<=bank_t'(pick); emit_valid<=1;
          emit_write_table<=token[pick][6];
          emit_data<=table_ram[pick][drained[pick]];
        end
      end
    end
  end
  // synthesis translate_off
  initial if (BANKS<1 || BANKS>16) $fatal(1,"fetch consumer BANKS must be1..16");
  assert property (@(posedge clk) disable iff(!rstn)
    emit_valid && !emit_ready |=> emit_valid && $stable({emit_data,emit_write_table}));
  assert property (@(posedge clk) disable iff(!rstn)
    diagnostic_valid && !diagnostic_ready |=> diagnostic_valid && $stable(diagnostic_word));
  assert property (@(posedge clk) disable iff(!rstn)
    local_error_valid && !local_error_ready |=> local_error_valid &&
      $stable({local_error_epoch,local_error_token,local_error_reason,local_error_count}));
  assert property (@(posedge clk) disable iff(!rstn)
    status_valid && status_ready && status_v2_success(status_word) |->
      sb>=0 && bound[sb] && sealed[sb] && !poisoned[sb] && received[sb]==needed[sb]);
  for (genvar g=0;g<BANKS;g++) begin : invariants
    assert property (@(posedge clk) disable iff(!rstn)
      live[g] |-> drained[g]<=received[g] && received[g]<=needed[g]);
    assert property (@(posedge clk) disable iff(!rstn)
      live[g] |-> int'(received[g])==$countones(seen[g]) && (seen[g]>>needed[g])=='0);
    assert property (@(posedge clk) disable iff(!rstn)
      committed[g] |-> sealed[g] && !poisoned[g] && received[g]==needed[g]);
    assert property (@(posedge clk) disable iff(!rstn)
      emit_valid && emit_bank==g |-> live[g] && committed[g]);
    assert property (@(posedge clk) disable iff(!rstn)
      $fell(live[g]) |-> $past(receipt[g]==3 && drained[g]==needed[g]));
    assert property (@(posedge clk) disable iff(!rstn)
      $rose(committed[g]) |-> $past(status_valid && status_ready &&
                                   status_v2_success(status_word) && sb==g));
    assert property (@(posedge clk) disable iff(!rstn)
      receipt[g]==3 && $past(receipt[g])!=3 |->
        $past(receipt_active && receipt_bank==g && receipt[g]==2 &&
              !ack_valid && !ack_consumed && !fault && !bad_event));
  end
  // synthesis translate_on
endmodule
