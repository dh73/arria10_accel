// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
// Consumer unit tests. Bind/status stimuli model the owner boundary; the
// separate controller test exercises the actual transformed DCS/DTS/TX paths.
module dma_fetch_commit_v4_tb;
  import dma_status_v2_pkg::*;
  logic clk=0, rstn=0, enable=0;
  always #5 clk=~clk;
  logic [31:0] epoch=32'h101;
  logic issue_valid=0, bind_valid=0, payload_valid=0, end_valid=0;
  wire issue_offer=issue_valid;
  logic abort_valid=0, status_valid=0, ack_valid=0, ack_consumed=0;
  logic emit_ready=0, diagnostic_ready=0, local_error_ready=0;
  logic [159:0] issue_desc=0, bind_desc=0, payload_data=0;
  logic [7:0] issue_first=0;
  logic [19:0] bind_token=0, payload_token=0, end_token=0, abort_token=0;
  logic [31:0] payload_epoch=0, end_epoch=0, abort_epoch=0;
  logic [6:0] payload_index=0;
  logic payload_write_table=0, end_error=0;
  logic [31:0] status_word=0, ack_word=0;
  wire issue_ready, payload_ready, end_ready, abort_ready, status_ready;
  wire emit_valid, emit_write_table, diagnostic_valid, fault;
  wire [159:0] emit_data;
  wire [31:0] diagnostic_word, fault_epoch;
  wire [19:0] fault_token;
  wire [7:0] fault_reason, fault_index;
  wire local_error_valid;
  wire [31:0] local_error_epoch;
  wire [19:0] local_error_token;
  wire [7:0] local_error_reason, local_error_count;
  dma_fetch_commit_v4 dut (.*);
  int scenario=0, kind=0, expectations=0, emissions=0, diagnostics=0;
  logic [159:0] expected_data[1024];
  logic [19:0] expected_token[1024];
  bit expected_seen[1024], expected_allowed[1024];
  bit allow_fault=0, held_emit=0, held_diag=0, held_local=0;
  logic [160:0] held_emission;
  logic [31:0] held_diagnostic;
  logic [67:0] held_local_error;

  function automatic logic [159:0] fetch(input logic [7:0] id, input int count,
                                         input int serial);
    return {6'b0,id,18'(count*8),64'(32'h8000+serial*4096),
            64'(32'h100000+serial*4096)};
  endfunction
  function automatic logic [159:0] data_desc(input logic [7:0] id, input int serial);
    return {6'b0,id,18'd8,64'(32'h400000+serial*32),64'(32'h200000+serial*32)};
  endfunction
  function automatic logic [31:0] success(input logic [19:0] tok);
    return status_v2_make(tok[7:0],tok[11:8],tok[19:12],0,1,1,0,1);
  endfunction
  task automatic tick;
    @(posedge clk); @(negedge clk); #1;
  endtask
  task automatic reset_case;
    rstn=0; enable=0; issue_valid=0; bind_valid=0; payload_valid=0; end_valid=0;
    abort_valid=0; status_valid=0; ack_valid=0; ack_consumed=0;
    emit_ready=0; diagnostic_ready=0; local_error_ready=0; expectations=0; allow_fault=0;
    repeat(3) tick(); rstn=1; enable=1; tick(); tick();
  endtask
  task automatic expect_descriptor(input logic [19:0] tok, input logic [159:0] data);
    expected_token[expectations]=tok; expected_data[expectations]=data;
    expected_seen[expectations]=0; expected_allowed[expectations]=0; expectations++;
  endtask
  task automatic reserve(input logic [19:0] tok, input int count,
                         input int first, input int serial, input int delay_bind);
    issue_desc=fetch(tok[7:0],count,serial); issue_first=8'(first); issue_valid=1;
    bind_desc=issue_desc; bind_token=tok; bind_valid=delay_bind==0;
    #1; if (!issue_ready) $fatal(1,"expected free fetch context id=%0d",tok[7:0]);
    tick(); issue_valid=0; bind_valid=0;
    if (delay_bind!=0) begin
      repeat(delay_bind) tick(); bind_valid=1; tick(); bind_valid=0;
    end
  endtask
  task automatic payload(input logic [19:0] tok, input int ordinal,
                         input int first, input int serial);
    payload_token=tok; payload_epoch=epoch; payload_index=7'(ordinal);
    payload_write_table=tok[6]; payload_data=data_desc(8'(first+ordinal),serial);
    payload_valid=1; expect_descriptor(tok,payload_data);
    #1; if (!payload_ready) $fatal(1,"legal table beat refused ordinal=%0d",ordinal);
    tick(); payload_valid=0;
  endtask
  task automatic seal(input logic [19:0] tok);
    end_token=tok; end_epoch=epoch; end_error=0; end_valid=1;
    #1; if (!end_ready) $fatal(1,"legal transport close refused");
    tick(); end_valid=0;
  endtask
  task automatic send_status(input logic [31:0] word);
    status_word=word; status_valid=1;
    #1; while (!status_ready) tick();
    tick(); status_valid=0;
  endtask
  task automatic close_receipt(input logic [19:0] tok);
    ack_word=success(tok); ack_valid=1; ack_consumed=0;
    repeat(3) tick(); ack_consumed=1; repeat(3) tick();
    ack_valid=0; tick(); ack_consumed=0; repeat(3) tick();
  endtask
  task automatic check_reserved(input logic [19:0] tok, input int count,
                                input int first, input int serial);
    issue_desc=fetch(tok[7:0],count,serial); issue_first=8'(first); #1;
    if (issue_ready) $fatal(1,"context/ID recycled before both drain and receipt closure");
  endtask
  task automatic wait_emissions(input int target);
    while(emissions<target) tick();
    if (emissions!=target) $fatal(1,"extra executable descriptor");
  endtask

  always @(posedge clk) begin : scoreboard
    int found;
    if (!rstn) begin
      emissions=0; diagnostics=0; held_emit=0; held_diag=0; held_local=0;
    end else begin
      if (fault && !allow_fault)
        $fatal(1,"unexpected consumer fault reason=%0d token=%h",fault_reason,fault_token);
      if (held_emit && {emit_valid,emit_write_table,emit_data} !==
                       {1'b1,held_emission}) $fatal(1,"stalled executable descriptor changed");
      held_emit=emit_valid && !emit_ready;
      if (held_emit) held_emission={emit_write_table,emit_data};
      if (held_diag && (!diagnostic_valid || diagnostic_word!==held_diagnostic))
        $fatal(1,"retained diagnostic changed while backpressured");
      held_diag=diagnostic_valid && !diagnostic_ready;
      if (held_diag) held_diagnostic=diagnostic_word;
      if (held_local && (!local_error_valid ||
          {local_error_epoch,local_error_token,local_error_reason,local_error_count}!==held_local_error))
        $fatal(1,"retained transport error changed while backpressured");
      held_local=local_error_valid && !local_error_ready;
      if (held_local)
        held_local_error={local_error_epoch,local_error_token,local_error_reason,local_error_count};
      if (status_valid && status_ready && status_v2_success(status_word))
        for(int j=0;j<expectations;j++)
          if(expected_token[j]=={status_word[23:16],status_word[15:12],status_word[7:0]})
            expected_allowed[j]=1;
      if (emit_valid && emit_ready) begin
        found=-1;
        for(int j=0;j<expectations;j++)
          if(expected_data[j]===emit_data && !expected_seen[j]) found=j;
        if(found<0) $fatal(1,"unknown/duplicate executable descriptor %h",emit_data);
        if(!expected_allowed[found] || emit_write_table!==expected_token[found][6])
          $fatal(1,"uncommitted table executed or read/write destination aliased");
        // Within a table, each ordinal enters its destination in source order.
        for(int j=0;j<expectations;j++)
          if(expected_token[j]==expected_token[found] &&
             expected_data[j][153:146]<emit_data[153:146] && !expected_seen[j])
            $fatal(1,"descriptor ordinal reordered");
        expected_seen[found]=1; emissions++;
      end
      if(diagnostic_valid && diagnostic_ready) diagnostics++;
    end
  end

  initial begin : stimulus
    logic [19:0] r, w, t;
    logic [31:0] pause_word, error_word;
    int before_count;
    if (!$value$plusargs("SCENARIO=%d",scenario)) scenario=0;
    if (!$value$plusargs("KIND=%d",kind)) kind=0;
    reset_case();
    r={8'd1,4'd0,8'd128}; w={8'd6,4'd1,8'd192};
    case(scenario)
      0: begin
        reserve(r,3,7,1,4); reserve(w,3,29,2,0);
        payload(r,2,7,12); payload(w,0,29,20); payload(r,0,7,10);
        payload(w,2,29,22); payload(w,1,29,21); seal(w);
        status_word=success(r); status_valid=1;
        repeat(7) begin tick(); if(status_ready || emit_valid)
          $fatal(1,"early success bypassed missing payload"); end
        payload(r,1,7,11);
        repeat(4) begin tick(); if(status_ready || emit_valid)
          $fatal(1,"complete table bypassed producer closure"); end
        seal(r); #1;
        if(!status_ready) $fatal(1,"complete sealed table could not commit");
        tick(); status_valid=0; send_status(success(w));
        wait(emit_valid); repeat(9) tick();
        close_receipt(r); check_reserved(r,3,7,1);
        for(int j=0;j<30;j++) begin emit_ready=(j%3)!=0; tick(); end
        emit_ready=1; wait_emissions(6);
        check_reserved(w,3,29,2); close_receipt(w); tick();
        // Repeated ownership with full ID and generation recurrence. No reset.
        for(int j=0;j<320;j++) begin
          t={8'((j%255)+1),4'd0,8'(128+((j%2)*64)+((j/2)%64))};
          reserve(t,1,37,j+100,j%3);
          payload(t,0,37,j+100); seal(t); before_count=emissions;
          emit_ready=0; send_status(success(t));
          if(j%2==0) begin close_receipt(t); check_reserved(t,1,37,j+100); end
          repeat(j%5) tick(); emit_ready=1; wait_emissions(before_count+1);
          if(j%2!=0) begin check_reserved(t,1,37,j+100); close_receipt(t); end
          repeat(3) tick();
        end
        if(emissions!=326 || diagnostics!=0 || fault) $fatal(1,"reuse accounting mismatch");
      end
      1: begin
        reserve(r,2,10,1,2); reserve(w,2,20,2,1);
        payload(r,0,10,10); payload(w,0,20,20);
        pause_word=status_v2_make(w[7:0],w[11:8],w[19:12],DMA_CAUSE_PAUSE,0,0,0,0);
        error_word=status_v2_make(r[7:0],r[11:8],r[19:12],DMA_CAUSE_MASTER,0,1,1,0);
        send_status(pause_word); wait(diagnostic_valid); repeat(7) tick();
        send_status(error_word); repeat(5) begin tick();
          if(diagnostic_word!==pause_word) $fatal(1,"new error replaced stalled pause"); end
        diagnostic_ready=1; tick(); diagnostic_ready=0;
        wait(diagnostic_valid); if(diagnostic_word!==error_word) $fatal(1,"lost terminal error");
        repeat(5) tick(); diagnostic_ready=1; tick(); diagnostic_ready=0;
        payload(w,1,20,21); seal(w); send_status(success(w));
        emit_ready=1; wait_emissions(2); close_receipt(w);
        // Error notification is not producer close. Matching late data remains owned.
        payload(r,1,10,11); seal(r); repeat(5) tick(); check_reserved(r,2,10,1);
        if(diagnostics!=2 || emissions!=2 || fault) $fatal(1,"pause/error accounting mismatch");
        // A later contradictory success is a retained protocol error, not an ACK.
        allow_fault=1; status_word=success(r); status_valid=1; tick();
        if(!fault || fault_reason!=5 || status_ready || emit_valid)
          $fatal(1,"poisoned-success contradiction escaped containment");
      end
      2: begin
        reserve(r,2,10,1,1); payload(r,0,10,10); allow_fault=1;
        payload_token=r; payload_epoch=epoch; payload_index=1;
        payload_write_table=0; payload_data=data_desc(11,11);
        case(kind)
          0: begin payload_index=0; payload_data=data_desc(10,10); payload_valid=1; end
          1: begin payload_token={8'd2,4'd0,8'd128}; payload_valid=1; end
          2: begin payload_write_table=1; payload_valid=1; end
          3: begin payload_index=2; payload_data=data_desc(12,12); payload_valid=1; end
          4: begin payload_data=data_desc(12,12); payload_valid=1; end
          5: begin payload(r,1,10,11); seal(r); payload_valid=1; end
          6: begin end_token=r; end_epoch=epoch; end_valid=1; end_error=0; end
          7: begin payload(r,1,10,11); end_token=r; end_epoch=epoch;
                   end_valid=1; end_error=1; end
          8: begin status_word=success({8'd1,4'd0,8'd192}); status_valid=1; end
          9: begin bind_token={8'd1,4'd0,8'd192}; bind_desc=fetch(128,2,1); bind_valid=1; end
          10: begin payload_epoch=epoch-1; payload_valid=1; end
          11: epoch=epoch+1;
          12: begin issue_desc=fetch(129,0,3); issue_first=0; issue_valid=1; end
          default: $fatal(1,"unknown negative KIND");
        endcase
        tick();
        if(kind==6 || kind==7) begin
          end_valid=0;
          wait(local_error_valid);
          if(fault || emit_valid || local_error_token!==r || local_error_epoch!==epoch ||
             local_error_reason!==(kind==6 ? 8'd2 : 8'd1) ||
             local_error_count!==(kind==6 ? 8'd1 : 8'd2))
            $fatal(1,"partial/error closure lost its retained local error");
          repeat(6) tick(); local_error_ready=1; tick(); local_error_ready=0;
          check_reserved(r,2,10,1);
        end else if(!fault || emit_valid || status_ready)
          $fatal(1,"invalid input escaped containment");
        if(kind<=5 || kind==10) begin
          if(payload_ready || fault_reason!=3 || fault_token!==payload_token)
            $fatal(1,"payload refusal lost exact diagnostic identity");
        end
        repeat(6) tick();
      end
      3: begin
        reserve(r,1,10,1,0); payload(r,0,10,10); seal(r);
        allow_fault=1;
        status_word=success(r); status_valid=1;
        abort_token=r; abort_epoch=epoch; abort_valid=1; #1;
        if(!abort_ready || status_ready) $fatal(1,"same-edge abort did not veto commit");
        tick(); abort_valid=0;
        repeat(6) begin tick(); if(status_ready || emit_valid)
          $fatal(1,"aborted table became executable"); end
        status_valid=0; check_reserved(r,1,10,1);
        if(!local_error_valid || local_error_token!==r || local_error_reason!=3)
          $fatal(1,"precommit abort not retained");
        if(!fault || fault_reason!=5) $fatal(1,"held success after abort not diagnosed");
      end
      4: begin
        // Reset containment is local; epoch is a required fabric contract.
        reserve(r,2,10,1,0); payload(r,0,10,10);
        epoch=epoch+1; reset_case();
        reserve(r,2,10,2,1); allow_fault=1;
        payload_token=r; payload_epoch=epoch-1; payload_index=0;
        payload_data=data_desc(10,10); payload_write_table=0; payload_valid=1;
        tick(); if(!fault || fault_reason!=3 || payload_ready || emit_valid)
          $fatal(1,"pre-reset payload reached new epoch");
      end
      5: begin
        r={8'd1,4'd0,8'd191}; w={8'd1,4'd1,8'd255};
        reserve(r,128,0,1,0); reserve(w,128,0,2,1);
        for(int j=127;j>=0;j--) begin
          payload(r,j,0,1000+j); payload(w,127-j,0,2000+127-j);
        end
        seal(r); seal(w); send_status(success(r)); send_status(success(w));
        close_receipt(r); close_receipt(w); emit_ready=1; wait_emissions(256);
        repeat(4) tick();
        if(fault || emissions!=256) $fatal(1,"full128 table boundary failed");
      end
      6: begin
        issue_desc=fetch(128,1,1); issue_first=10; issue_valid=1; #1;
        if(!issue_ready) $fatal(1,"reserve before delayed bind failed");
        tick(); issue_valid=0;
        payload_token=r; payload_epoch=epoch; payload_index=0;
        payload_write_table=0; payload_data=data_desc(10,10); payload_valid=1;
        expect_descriptor(r,payload_data); status_word=success(r); status_valid=1;
        repeat(7) begin tick(); if(fault || payload_ready || status_ready)
          $fatal(1,"unbound traffic accepted or incorrectly faulted"); end
        bind_desc=issue_desc; bind_token=r; bind_valid=1; tick(); bind_valid=0;
        #1; if(!payload_ready || status_ready) $fatal(1,"authoritative delayed bind not joined");
        tick(); payload_valid=0; seal(r); tick(); status_valid=0;
        emit_ready=1; wait_emissions(1); close_receipt(r);
      end
      7: begin
        reserve(r,2,10,1,0); reserve(w,1,20,2,1); payload(r,0,10,10);
        seal(r); wait(local_error_valid); repeat(5) tick();
        payload(w,0,20,20); seal(w); send_status(success(w)); emit_ready=1;
        wait_emissions(1); close_receipt(w);
        if(fault || !local_error_valid || local_error_token!==r || local_error_reason!=2)
          $fatal(1,"partial local close lost identity or blocked independent table");
        local_error_ready=1; tick(); local_error_ready=0; check_reserved(r,2,10,1);
      end
      8: begin
        // Exact full token recurrence: fixed ID/slot, generation1..255 then1.
        for(int j=0;j<256;j++) begin
          t={8'((j%255)+1),4'd0,8'd128};
          reserve(t,1,17,j+1,j%2); payload(t,0,17,j+1); seal(t);
          emit_ready=0; send_status(success(t)); close_receipt(t);
          check_reserved(t,1,17,j+1); emit_ready=1; wait_emissions(j+1);
          repeat(3) tick();
        end
        if(emissions!=256 || fault) $fatal(1,"full token recurrence failed");
      end
      9: begin
        reserve(r,1,10,1,0); payload(r,0,10,10); seal(r); send_status(success(r));
        allow_fault=1; ack_word=success(r); ack_valid=1;
        if(kind==0) ack_word=success({8'd2,4'd0,8'd128});
        tick();
        if(kind!=0) begin
          ack_consumed=1; tick();
          if(kind==1) begin ack_valid=0; ack_consumed=0; end
          else if(kind==2) ack_word=success({8'd1,4'd1,8'd128});
          else $fatal(1,"unknown receipt KIND");
          tick();
        end
        if(!fault || fault_reason!=8) $fatal(1,"bad fourphase receipt was accepted");
        check_reserved(r,1,10,1); repeat(5) tick();
      end
      default: $fatal(1,"unknown SCENARIO");
    endcase
    $display("PASS fetch_commit_v4 scenario=%0d kind=%0d emissions=%0d diagnostics=%0d",scenario,kind,emissions,diagnostics);
    $finish;
  end
endmodule
