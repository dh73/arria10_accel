// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
// Focused local control for the copier repair. The full composition bench owns
// controller/MRd/return qualification. Here only the actual owned consumer is
// instantiated; its documented interfaces are driven directly, never forced.
// Status and four-phase receipts are delivered in issue order, as the real
// owner requires. Holding emit_ready establishes the simultaneous committed
// banks that the previous round-robin copier mishandled.
module consumer_order_tb;
  import dma_status_v2_pkg::*;
  logic clk=0, rstn=0, enable=0;
  always #5 clk=~clk;
  logic [31:0] epoch=32'hc001;
  logic issue_offer=0, issue_valid=0, bind_valid=0;
  logic [159:0] issue_desc=0, bind_desc=0;
  logic [7:0] issue_first=0;
  logic [19:0] bind_token=0;
  wire issue_ready;
  logic payload_valid=0, payload_write_table=0;
  logic [19:0] payload_token=0;
  logic [6:0] payload_index=0;
  logic [159:0] payload_data=0;
  wire payload_ready;
  logic end_valid=0;
  logic [19:0] end_token=0;
  wire end_ready, unused_abort_ready;
  logic status_valid=0;
  logic [31:0] status_word=0;
  wire status_ready;
  logic ack_valid=0, ack_consumed=0;
  logic [31:0] ack_word=0;
  wire emit_valid, emit_write_table;
  wire [159:0] emit_data;
  logic emit_ready=0;
  wire diagnostic_valid, local_valid, fault;
  wire [31:0] diagnostic_word, local_epoch, fault_epoch;
  wire [19:0] local_token, fault_token;
  wire [7:0] local_reason, local_count, fault_reason, fault_index;

  dma_fetch_commit_return_v5 dut (
    .clk(clk), .rstn(rstn), .enable(enable), .epoch(epoch),
    .fabric_fault(1'b0), .fabric_reason(8'b0), .fabric_epoch(32'b0),
    .fabric_token(20'b0), .fabric_index(8'b0),
    .issue_offer(issue_offer), .issue_valid(issue_valid), .issue_ready(issue_ready),
    .issue_desc(issue_desc), .issue_first(issue_first),
    .bind_valid(bind_valid), .bind_desc(bind_desc), .bind_token(bind_token),
    .payload_valid(payload_valid), .payload_ready(payload_ready),
    .payload_write_table(payload_write_table), .payload_epoch(epoch),
    .payload_token(payload_token), .payload_index(payload_index), .payload_data(payload_data),
    .end_valid(end_valid), .end_ready(end_ready), .end_epoch(epoch),
    .end_token(end_token), .end_error(1'b0),
    .abort_valid(1'b0), .abort_ready(unused_abort_ready), .abort_epoch(32'b0), .abort_token(20'b0),
    .status_valid(status_valid), .status_ready(status_ready), .status_word(status_word),
    .ack_valid(ack_valid), .ack_consumed(ack_consumed), .ack_word(ack_word),
    .emit_valid(emit_valid), .emit_ready(emit_ready),
    .emit_write_table(emit_write_table), .emit_data(emit_data),
    .diagnostic_valid(diagnostic_valid), .diagnostic_ready(1'b0), .diagnostic_word(diagnostic_word),
    .local_error_valid(local_valid), .local_error_ready(1'b0), .local_error_epoch(local_epoch),
    .local_error_token(local_token), .local_error_reason(local_reason), .local_error_count(local_count),
    .fault(fault), .fault_reason(fault_reason), .fault_epoch(fault_epoch),
    .fault_token(fault_token), .fault_index(fault_index)
  );

  logic [159:0] expected_read[$], expected_write[$];
  logic [19:0] token [4];
  int read_seen=0, write_seen=0, issues=0, payloads=0, ends=0, commits=0, receipts=0;
  int receipt_phase=0;
  bit collision_armed=0, held_emit=0;
  logic [160:0] held_data;

  function automatic logic [159:0] executable(input int id);
    return {6'd0,8'(id),18'd8,
            64'h400000+64'($unsigned(id))*64'd32,
            64'h200000+64'($unsigned(id))*64'd32};
  endfunction

  task automatic tick;
    @(posedge clk); @(negedge clk); #1;
  endtask

  task automatic reserve(input int id, input int first, input int slot,
                         output logic [19:0] tok);
    issue_desc={6'd0,8'(id),18'd16,
                id>=192 ? 64'h80002000 : 64'h80000000,
                64'h1000+64'($unsigned(slot))*64'd64};
    issue_first=8'($unsigned(first)); issue_offer=1;
    #1; while(!issue_ready) tick();
    tok={8'd1,4'(slot),8'(id)};
    bind_desc=issue_desc; bind_token=tok;
    issue_valid=1; bind_valid=1;
    tick(); issue_valid=0; issue_offer=0; bind_valid=0;
  endtask

  task automatic supply_table(input logic [19:0] tok, input int first);
    for(int ordinal=0;ordinal<2;ordinal++) begin
      payload_token=tok; payload_write_table=tok[6]; payload_index=7'($unsigned(ordinal));
      payload_data=executable(first+ordinal); payload_valid=1;
      #1; while(!payload_ready) tick(); tick(); payload_valid=0;
    end
    end_token=tok; end_valid=1;
    #1; while(!end_ready) tick(); tick(); end_valid=0;
  endtask

  task automatic publish_in_order(input logic [19:0] tok);
    status_word=status_v2_make(tok[7:0],tok[11:8],tok[19:12],0,1,1,0,1);
    status_valid=1; #1; while(!status_ready) tick(); tick(); status_valid=0;
    ack_word=status_word; ack_valid=1; ack_consumed=0; tick();
    ack_consumed=1; tick();
    ack_valid=0; ack_word=0; tick();
    ack_consumed=0; tick();
  endtask

  always @(posedge clk) if(rstn) begin : monitor
    logic [159:0] expected;
    int observed_id, expected_id;
    if(fault || diagnostic_valid || local_valid)
      $fatal(1,"consumer order fixture unexpected fault reason=%0d token=%h",fault_reason,fault_token);
    if(issue_valid && issue_ready) issues++;
    if(payload_valid && payload_ready) payloads++;
    if(end_valid && end_ready) ends++;
    if(status_valid && status_ready) begin
      if(!status_v2_success(status_word)) $fatal(1,"fixture did not publish success");
      commits++;
    end
    case(receipt_phase)
      0: if(ack_valid && ack_consumed) receipt_phase=1;
      1: if(!ack_valid && ack_consumed) receipt_phase=2;
      2: if(!ack_valid && !ack_consumed) begin receipts++; receipt_phase=0; end
      default: $fatal(1,"fixture receipt phase");
    endcase
    if(held_emit && (!emit_valid || {emit_write_table,emit_data}!==held_data))
      $fatal(1,"copier changed its retained output");
    held_emit=emit_valid && !emit_ready;
    if(held_emit) held_data={emit_write_table,emit_data};
    if(emit_valid && emit_ready) begin
      if(!collision_armed || issues!=4 || commits!=4 || receipts!=4 ||
         payloads!=8 || ends!=4)
        $fatal(1,"order collision precondition was not established");
      if(emit_write_table) begin
        if(write_seen>=expected_write.size()) $fatal(1,"duplicate write copier entry");
        expected=expected_write[write_seen];
      end else begin
        if(read_seen>=expected_read.size()) $fatal(1,"duplicate read copier entry");
        expected=expected_read[read_seen];
      end
      observed_id=int'(emit_data[153:146]); expected_id=int'(expected[153:146]);
      // A negative run accepts ONLY this named witness after the simultaneous
      // committed/held-copier preconditions above. Any other fatal is a failure.
      if(observed_id!=expected_id)
        $fatal(1,"EXPECTED_ORDER_VIOLATION expected=%0d actual=%0d",expected_id,observed_id);
      if(emit_data!==expected) $fatal(1,"copier data differs from independent expected table");
      if(emit_write_table) write_seen++; else read_seen++;
    end
  end

  initial begin
    // Expected destination streams are set before issuing anything. They never
    // read a DUT RAM, output, generated token, or arbitration decision.
    expected_read.push_back({6'd0,8'd0,18'd8,64'h400000,64'h200000});
    expected_read.push_back({6'd0,8'd1,18'd8,64'h400020,64'h200020});
    expected_read.push_back({6'd0,8'd2,18'd8,64'h400040,64'h200040});
    expected_read.push_back({6'd0,8'd3,18'd8,64'h400060,64'h200060});
    expected_write.push_back({6'd0,8'd10,18'd8,64'h400140,64'h200140});
    expected_write.push_back({6'd0,8'd11,18'd8,64'h400160,64'h200160});
    expected_write.push_back({6'd0,8'd12,18'd8,64'h400180,64'h200180});
    expected_write.push_back({6'd0,8'd13,18'd8,64'h4001a0,64'h2001a0});
    repeat(3) tick(); rstn=1; enable=1; tick();
    reserve(128,0,0,token[0]); reserve(192,10,1,token[1]);
    reserve(129,2,2,token[2]); reserve(193,12,3,token[3]);
    // Return-order variation does not relax owner status/receipt ordering.
    supply_table(token[3],12); supply_table(token[2],2);
    supply_table(token[1],10); supply_table(token[0],0);
    for(int k=0;k<4;k++) publish_in_order(token[k]);
    if(issues!=4 || payloads!=8 || ends!=4 || commits!=4 || receipts!=4 ||
       read_seen!=0 || write_seen!=0 || !emit_valid ||
       emit_write_table || emit_data!==expected_read[0])
      $fatal(1,"held copier / committed-bank collision missing");
    collision_armed=1; emit_ready=1;
    wait(read_seen==4 && write_seen==4); tick();
    if(emit_valid || fault || receipt_phase!=0)
      $fatal(1,"ordered copier did not settle the directed fixture");
    $display("PASS consumer-order-v1 read=4 write=4 commits=4 receipts=4");
    $finish;
  end
endmodule
