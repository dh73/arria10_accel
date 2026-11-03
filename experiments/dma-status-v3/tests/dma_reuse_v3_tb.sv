// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
module dma_reuse_v3_tb;
import dma_status_v2_pkg::*;
localparam int PERIOD = 255;
localparam int WRAPS = 3;
localparam int BATCHES = WRAPS * PERIOD + 1;
localparam int LIFECYCLES = 16 * BATCHES;
logic clk = 0, rstn = 0;
always #5 clk = ~clk;
logic descriptor_valid = 0, descriptor_room = 1;
logic [7:0] descriptor_id = 0;
wire descriptor_ready;
wire [3:0] descriptor_slot;
logic start_valid = 0, current_valid = 0, issue_valid = 0, return_valid = 0;
logic command_valid = 0, retire_valid = 0, close_valid = 0, master_error = 0;
logic [3:0] start_slot = 0, current_slot = 0, issue_slot = 0, return_slot = 0;
logic [3:0] command_slot = 0, retire_slot = 0, close_slot = 0;
logic control_valid = 0;
logic [3:0] control_data = 0;
wire control_ready;
wire [15:0] halted;
logic external_fault = 0;
wire contract_fault, status_valid, status_ready;
wire [31:0] status_word;
wire ack_valid, ack_consumed;
wire [31:0] ack_word;
wire sink_ready, sink_ack_valid, sink_fault;
wire [31:0] sink_ack_word, sink_fault_word;
logic ingress_pause = 0, ack_return_block = 0;
logic ingress_hold = 0, sink_ack_consumed = 0;
wire ingress_enable = ingress_hold || !ingress_pause;
logic inject_ack = 0, injected_valid = 0;
logic [31:0] injected_word = 0;
logic dcm_waitrequest = 0, fetch_ready = 0, diagnostic_ready = 0;
logic [63:0] header_base = 64'h8000;
logic [81:0] msi_interface = {1'b0, 1'b1, 16'hbeef, 64'ha000};
wire dcm_write, fetch_valid, diagnostic_valid;
wire [63:0] dcm_address;
wire [31:0] dcm_data, fetch_word, diagnostic_word;
wire [3:0] dcm_byteenable;
bit auto_transport = 0, allow_fault = 0, check_success = 0, check_errors = 0;
int scenario = 0, cycles = 0, admissions = 0, statuses = 0;
int publications = 0, receipts = 0, closures = 0;
int fetch_at = -1, last_publication_at = -1;
bit previous_ack = 0, pending_msi = 0;
logic [31:0] held_receipt = 0;
bit released_last_edge = 0;
logic [3:0] released_slot = 0;
logic [31:0] first_tokens[16];
int repeated_tokens[16];

assign status_ready = sink_ready && ingress_enable;
assign ack_valid = inject_ack ? injected_valid : sink_ack_valid;
assign ack_word = inject_ack ? injected_word : sink_ack_word;
dma_owner_v3 owner (.*);
dma_status_sink_v3 #(.DEPTH(4)) sink (
  .clk(clk), .rstn(rstn),
  .s_valid(status_valid && ingress_enable), .s_ready(sink_ready),
  .s_word(status_word), .s_msi(status_word[15:12] % 3 == 0),
  .header_base(header_base), .msi_interface(msi_interface),
  .dcm_write(dcm_write), .dcm_address(dcm_address), .dcm_data(dcm_data),
  .dcm_byteenable(dcm_byteenable), .dcm_waitrequest(dcm_waitrequest),
  .fetch_valid(fetch_valid), .fetch_ready(fetch_ready), .fetch_word(fetch_word),
  .diagnostic_valid(diagnostic_valid), .diagnostic_ready(diagnostic_ready),
  .diagnostic_word(diagnostic_word), .retired_ack_valid(sink_ack_valid),
  .retired_ack_word(sink_ack_word),
  .retired_ack_consumed(sink_ack_consumed),
  .protocol_fault(sink_fault), .fault_word(sink_fault_word)
);

// Test-only delay adapters preserve the level handshake after exposing it.
// A periodic stall must not withdraw either a pending valid or consumed-high.
always @(posedge clk) begin
  if (!rstn) begin
    ingress_hold <= 0;
    sink_ack_consumed <= 0;
  end else begin
    if (status_valid && status_ready) ingress_hold <= 0;
    else if (status_valid && ingress_enable) ingress_hold <= 1;
    if (!ack_consumed) sink_ack_consumed <= 0;
    else if (!ack_return_block) sink_ack_consumed <= 1;
  end
end

function automatic logic [7:0] identity(input int slot);
  return slot == 14 ? 8'd128 : slot == 15 ? 8'd192 : 8'(7 + slot);
endfunction
function automatic logic [31:0] expected_success(input int index);
  return status_v2_make(identity(index % 16), 4'(index % 16),
                       8'((index / 16) % PERIOD + 1), 0, 1, 1, 0, 1);
endfunction
function automatic logic [31:0] expected_error(input int slot);
  return status_v2_make(identity(slot), 4'(slot), 1,
                       slot == 0 ? 4'h9 : DMA_CAUSE_FLUSH, 0, 1, 1, 0);
endfunction

// These periods define fair test stimulus, not a runtime or retry limit.
always @(negedge clk) begin
  if (rstn && released_last_edge && owner.live_q[released_slot])
    $fatal(1, "receipt withdrawal did not free the exact owner before reuse");
  if (rstn && auto_transport) begin
    dcm_waitrequest = (cycles % 9) < 3;
    fetch_ready = (cycles % 7) >= 3;
    diagnostic_ready = (cycles % 11) >= 5;
    ingress_pause = (cycles % 13) < 4;
    ack_return_block = (cycles % 17) < 9;
  end
end

always @(posedge clk) begin : scoreboard
  logic [31:0] expected;
  int slot;
  cycles++;
  released_last_edge = rstn && owner.ack_release;
  if (released_last_edge) released_slot = owner.receipt_word_q[15:12];
  if (rstn) begin
    if ((contract_fault || sink_fault) && !allow_fault)
      $fatal(1, "unexpected protocol fault owner=%b sink=%b word=%h",
             contract_fault, sink_fault, sink_fault_word);
    if (descriptor_valid && descriptor_ready) admissions++;
    if (status_valid && status_ready) begin
      if (check_success) begin
        expected = expected_success(statuses);
        if (status_word !== expected)
          $fatal(1, "success admission order/token mismatch index=%0d got=%h expected=%h",
                 statuses, status_word, expected);
        slot = statuses % 16;
        if (statuses < 16) first_tokens[slot] = status_word;
        if (status_word == first_tokens[slot]) repeated_tokens[slot]++;
      end else if (check_errors && status_word !== expected_error(statuses))
        $fatal(1, "queued error identity/cause mismatch index=%0d got=%h", statuses, status_word);
      statuses++;
    end
    if (check_success && dcm_write && !dcm_waitrequest) begin
      slot = publications % 16;
      if (slot >= 14 || dcm_byteenable !== 4'hf)
        $fatal(1, "fetch aliased a data row or byteenable changed");
      if (pending_msi) begin
        if (dcm_address !== 64'ha000 || dcm_data !== 32'hbeef)
          $fatal(1, "MSI identity/configuration/order changed");
        pending_msi = 0;
        publications++;
        last_publication_at = cycles;
      end else begin
        if (dcm_address !== 64'h8000 + 4 * identity(slot) || dcm_data !== 32'h1)
          $fatal(1, "wrong flag publication slot=%0d address=%h data=%h", slot, dcm_address, dcm_data);
        if (slot % 3 == 0) pending_msi = 1;
        else begin publications++; last_publication_at = cycles; end
      end
    end
    if (check_success && fetch_valid && fetch_ready) begin
      if (fetch_word !== expected_success(publications) || publications % 16 < 14)
        $fatal(1, "wrong fetch identity/order");
      publications++;
      fetch_at = cycles;
      last_publication_at = cycles;
    end
    if (check_errors && dcm_write && !dcm_waitrequest) begin
      slot = publications;
      if (pending_msi) begin
        if (dcm_address !== 64'ha000 || dcm_data !== 32'hbeef)
          $fatal(1, "error MSI snapshot/order changed");
        pending_msi = 0;
        publications++;
      end else begin
        if (slot >= 14 || dcm_address !== 64'h8000 + 4 * identity(slot) ||
            dcm_data !== expected_error(slot) || dcm_byteenable !== 4'hf)
          $fatal(1, "error publication lost own row/cause slot=%0d data=%h", slot, dcm_data);
        if (slot % 3 == 0) pending_msi = 1;
        else publications++;
      end
    end
    if (check_errors && diagnostic_valid && diagnostic_ready) begin
      if (publications < 14 || diagnostic_word !== expected_error(publications))
        $fatal(1, "fetch diagnostic identity/order mismatch");
      publications++;
    end
    if (check_errors && (fetch_valid || sink_ack_valid || ack_consumed))
      $fatal(1, "error or paused owner authorized retirement");
    if (sink_ack_valid && !previous_ack) begin
      held_receipt = sink_ack_word;
      if (check_success) begin
        if (sink_ack_word !== expected_success(receipts) || publications != receipts + 1 ||
            pending_msi || cycles <= last_publication_at)
          $fatal(1, "receipt before final publication or wrong order");
        if (sink_ack_word[7] && cycles < fetch_at + 2)
          $fatal(1, "fetch receipt bypassed retained consumer edge");
      end
      receipts++;
    end
    if (sink_ack_valid && previous_ack && sink_ack_word !== held_receipt)
      $fatal(1, "sink changed a held receipt");
    previous_ack = sink_ack_valid;
    if (owner.ack_release) closures++;
    if (check_success && !contract_fault && !external_fault &&
        ack_consumed && !ack_valid && !owner.ack_release)
      $fatal(1, "healthy withdrawn receipt did not release its owner");
    if (check_success && ack_consumed && ack_valid &&
        !owner.live_q[ack_word[15:12]])
      $fatal(1, "held receipt prematurely released owner");
  end
end

task automatic tick;
  @(posedge clk); @(negedge clk); #1;
endtask
task automatic allocate(input logic [7:0] id, output logic [3:0] slot);
  descriptor_id = id; descriptor_valid = 1;
  #1;
  if (!descriptor_ready) $fatal(1, "unexpected admission backpressure id=%0d", id);
  slot = descriptor_slot;
  tick(); descriptor_valid = 0;
  start_slot = slot; start_valid = 1;
  tick(); start_valid = 0;
endtask
task automatic issue_command_close(input logic [3:0] slot);
  issue_valid = 1; issue_slot = slot;
  tick(); issue_valid = 0;
  command_valid = 1; command_slot = slot;
  return_valid = 1; return_slot = slot;
  close_valid = 1; close_slot = slot;
  tick(); command_valid = 0; return_valid = 0; close_valid = 0;
endtask
task automatic close_empty(input logic [3:0] slot);
  close_valid = 1; close_slot = slot;
  tick(); close_valid = 0;
endtask
task automatic await_closed(input int count);
  wait (closures == count);
  tick(); tick();
  if (ack_consumed || sink_ack_valid) $fatal(1, "receipt did not return to zero");
endtask
task automatic inject_bad(input logic [31:0] bad);
  allow_fault = 1; inject_ack = 1; injected_valid = 1; injected_word = bad;
  tick();
  if (!contract_fault) $fatal(1, "invalid receipt was accepted: %h", bad);
  if (closures != 0) $fatal(1, "invalid receipt released an owner");
endtask

initial begin : run
  logic [3:0] slot, other;
  logic [31:0] old_word, expected, held;
  int before_closures;
  if (!$value$plusargs("SCENARIO=%d", scenario)) scenario = 0;
  for (int i = 0; i < 16; i++) begin first_tokens[i] = 0; repeated_tokens[i] = 0; end
  repeat (3) @(negedge clk);
  rstn = 1;
  tick();
  case (scenario)
  0: begin
    check_success = 1; auto_transport = 1;
    // Fill all owners before retiring in reverse order. Every owner performs
    // actual issue/header/tag-return/last-command events on every allocation.
    // 766 batches cross the old 4080 total ceiling and three modulo turnovers
    // of every slot without resetting either endpoint or transport state.
    for (int batch = 0; batch < BATCHES; batch++) begin
      for (int i = 0; i < 16; i++) begin
        allocate(identity(i), slot);
        if (slot != i) $fatal(1, "owner allocator lost full-ring coverage");
        issue_command_close(slot);
      end
      descriptor_id = identity(0); #1;
      if (descriptor_ready) $fatal(1, "live duplicate ID or full owner ring admitted");
      for (int i = 15; i >= 0; i--) begin
        if (statuses != batch * 16)
          $fatal(1, "later completion bypassed the oldest unretired payload");
        retire_valid = 1; retire_slot = 4'(i);
        tick(); retire_valid = 0;
      end
      await_closed((batch + 1) * 16);
      if (statuses != (batch + 1) * 16 || publications != statuses ||
          receipts != statuses || owner.order_count != 0)
        $fatal(1, "batch accounting mismatch at %0d", batch);
    end
    auto_transport = 0;
    if (admissions != LIFECYCLES || closures != LIFECYCLES || LIFECYCLES <= 4080)
      $fatal(1, "did not cross former finite-service ceiling");
    for (int i = 0; i < 16; i++)
      if (repeated_tokens[i] != WRAPS + 1)
        $fatal(1, "slot%0d exact token did not recur after all%0d turnovers", i, WRAPS);
    $display("PASS reuse-v3 %0d payload lifecycles, %0d wraps per slot, exact repeated tokens, no reset", LIFECYCLES, WRAPS);
  end
  1: begin
    ack_return_block = 1;
    allocate(7, slot); close_empty(slot);
    wait (ack_consumed); tick(); old_word = ack_word;
    before_closures = closures;
    descriptor_id = 7;
    repeat (12) begin
      tick();
      if (!ack_valid || !ack_consumed || ack_word !== old_word ||
          descriptor_ready || closures != before_closures || !owner.live_q[slot])
        $fatal(1, "held ACK released/reconsumed owner or lost return signal");
    end
    ack_return_block = 0;
    await_closed(1);
    // The producer has returned low. A new unsolicited identical pulse is a
    // distinct illegal receipt, not another sample of the held handshake.
    allow_fault = 1; inject_ack = 1; injected_word = old_word; injected_valid = 1;
    tick();
    if (!contract_fault || closures != 1)
      $fatal(1, "duplicate after closure was not rejected exactly once");
    $display("PASS reuse-v3 held receipt closure and duplicate-after-return rejection");
  end
  2: begin
    allocate(7, slot); close_empty(slot);
    wait (sink_ack_valid); old_word = sink_ack_word;
    await_closed(1);
    inject_ack = 1;
    allocate(7, slot); close_empty(slot);
    wait (sink_ack_valid); tick();
    if (sink_ack_word[23:16] != 2) $fatal(1, "second allocation did not advance diagnostic generation");
    allow_fault = 1; injected_valid = 1; injected_word = old_word;
    tick();
    if (!contract_fault || closures != 1 || !owner.live_q[slot])
      $fatal(1, "previous-generation receipt released the new allocation");
    $display("PASS reuse-v3 stale previous-generation receipt rejection");
  end
  3: begin
    inject_ack = 1;
    allocate(7, slot); close_empty(slot);
    wait (sink_ack_valid); tick();
    injected_word = sink_ack_word; injected_valid = 1;
    tick();
    if (!ack_consumed) $fatal(1, "valid injected receipt did not enter closure");
    allow_fault = 1; injected_word[0] = ~injected_word[0];
    tick();
    if (!contract_fault || closures != 0 || !owner.live_q[slot])
      $fatal(1, "changed held receipt released the owner");
    $display("PASS reuse-v3 changed held receipt rejection");
  end
  4: begin
    ingress_pause = 1;
    allocate(7, slot); close_empty(slot);
    wait (status_valid); tick();
    inject_bad(status_v2_make(7, slot, 1, 0, 1, 1, 0, 1));
    $display("PASS reuse-v3 ACK before status delivery rejection");
  end
  5, 6, 7: begin
    inject_ack = 1;
    allocate(7, slot);
    if (scenario == 7) allocate(8, other);
    close_empty(slot);
    if (scenario == 7) close_empty(other);
    wait (sink_ack_valid); tick(); expected = sink_ack_word;
    case (scenario)
      5: expected[10:8] = 3'b111;
      6: expected[7:0] = 8'd8;
      7: expected = status_v2_make(8, other, 1, 0, 1, 1, 0, 1);
      default: ;
    endcase
    inject_bad(expected);
    $display("PASS reuse-v3 malformed/foreign/wrong-head receipt rejection scenario=%0d", scenario);
  end
  8: begin
    check_errors = 1; dcm_waitrequest = 1;
    for (int i = 0; i < 16; i++) begin
      allocate(identity(i), slot);
      if (slot != i) $fatal(1, "error ring allocation mismatch");
      issue_command_close(slot);
    end
    control_valid = 1; control_data = 8;
    master_error = 1; current_valid = 1; current_slot = 0;
    retire_valid = 1; retire_slot = 0;
    #1; if (!control_ready) $fatal(1, "flush not admitted at error boundary");
    tick(); control_valid = 0; master_error = 0; current_valid = 0; retire_valid = 0;
    for (int i = 1; i < 16; i++) begin
      retire_valid = 1; retire_slot = 4'(i);
      tick(); retire_valid = 0;
    end
    wait (statuses == 4 && status_valid && !status_ready);
    held = status_word;
    repeat (12) begin
      tick();
      if (statuses != 4 || !status_valid || status_word !== held ||
          publications || closures || sink_ready)
        $fatal(1, "finite sink full boundary lost or bypassed queued error");
    end
    dcm_waitrequest = 0; diagnostic_ready = 1;
    wait (statuses == 16 && publications == 16);
    repeat (6) tick();
    if (receipts || closures || owner.order_count != 16 || status_valid)
      $fatal(1, "error consumption freed an owner or lost identities");
    for (int i = 0; i < 16; i++) begin
      descriptor_id = identity(i); #1;
      if (descriptor_ready) $fatal(1, "quarantined identity readmitted");
    end
    $display("PASS reuse-v3 same-edge error+last-payload+flush, full sink, queued causes, fetch diagnostics, quarantine");
  end
  9: begin
    ack_return_block = 1;
    allocate(7, slot); close_empty(slot);
    wait (ack_consumed); tick();
    if (!sink_ack_valid || closures) $fatal(1, "missing held receipt before fault boundary");
    ack_return_block = 0;
    wait (!sink_ack_valid);
    // Source has withdrawn after consumed-high. This independent fault is
    // presented before the very edge that would ordinarily release the slot.
    allow_fault = 1; external_fault = 1;
    tick(); external_fault = 0;
    repeat (6) begin
      tick();
      if (!contract_fault || !ack_consumed || !owner.live_q[slot] ||
          owner.order_count != 1 || closures || descriptor_ready || sink_fault)
        $fatal(1, "withdrawal-edge fault released or rearmed quarantined custody");
    end
    $display("PASS reuse-v3 same-edge external fault blocks receipt withdrawal release");
  end
  default: $fatal(1, "unknown scenario=%0d", scenario);
  endcase
  $finish;
end
endmodule
