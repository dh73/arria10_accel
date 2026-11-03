// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
// Actual source-transformed controller, native scfifo, and actual owner.
// Read-engine command/return events below are abstract stimuli, not a PCIe fabric.
module dma_controller_fetch_v4_tb;
  import dma_status_v2_pkg::*;
  logic clk=0, rstn=0;
  always #5 clk=~clk;
  logic cs=0, cswrite=0, csread=0;
  logic [7:0] csaddr=0;
  logic [31:0] csdata=0;
  wire cswait; wire [31:0] csreaddata;
  logic host_stall=1, admission_enable=1, write_ready=0, diagnostic_ready=0;
  wire host_write; wire [63:0] host_address; wire [31:0] host_data;
  wire [3:0] host_be;
  logic rdcs=0, rdwrite=0, wrcs=0, wrwrite=0;
  logic [255:0] rddata=0, wrdata=0;
  logic [19:0] rdtoken=0, wrtoken=0;
  logic [6:0] rdindex=0, wrindex=0;
  logic [31:0] epoch=32'h111;
  wire rdwait, wrwait;
  logic end_valid=0, end_error=0, abort_valid=0;
  logic [19:0] end_token=0, abort_token=0;
  wire end_ready, abort_ready;
  logic forward_req=0; logic [159:0] forward_data=0;
  logic [7:0] forward_first=0;
  wire forward_ack, tx_valid, tx_ready, write_valid;
  wire [159:0] tx_data, write_data, issue_data;
  wire issue_valid; wire [7:0] issue_first;
  wire fetch_valid, fetch_ready; wire [31:0] fetch_word;
  wire diagnostic_valid, controller_fault, fetch_fault, local_valid;
  wire [31:0] diagnostic_word, controller_fault_word, fault_epoch, local_epoch;
  wire [19:0] fault_token, local_token;
  wire [7:0] fault_reason, fault_index, local_reason, local_count;
  wire descriptor_ready; wire [3:0] descriptor_slot;
  wire [19:0] descriptor_token;
  wire descriptor_valid=tx_valid && admission_enable;
  wire [7:0] descriptor_id=tx_data[153:146];
  wire descriptor_room=1'b1;
  wire bind_valid=descriptor_valid && descriptor_ready && descriptor_id[7];
  assign tx_ready=descriptor_ready && admission_enable;
  logic start_valid=0, current_valid=0, issue_valid_owner=0, return_valid=0;
  logic command_valid=0, retire_valid=0, close_valid=0, master_error=0;
  logic [3:0] start_slot=0, current_slot=0, issue_slot=0, return_slot=0;
  logic [3:0] command_slot=0, retire_slot=0, close_slot=0;
  logic control_valid=0; logic [3:0] control_data=0;
  wire control_ready; wire [15:0] halted;
  wire contract_fault, status_valid, status_ready, ack_valid, ack_consumed;
  wire [31:0] status_word, ack_word;
  dma_owner_fetch_v4 owner (
    .clk(clk),.rstn(rstn),.descriptor_valid(descriptor_valid),.descriptor_ready(descriptor_ready),
    .descriptor_room(descriptor_room),.descriptor_id(descriptor_id),.descriptor_slot(descriptor_slot),
    .descriptor_token(descriptor_token),.start_valid(start_valid),.start_slot(start_slot),
    .current_valid(current_valid),.current_slot(current_slot),
    .issue_valid(issue_valid_owner),.issue_slot(issue_slot),.return_valid(return_valid),.return_slot(return_slot),
    .command_valid(command_valid),.command_slot(command_slot),.retire_valid(retire_valid),.retire_slot(retire_slot),
    .close_valid(close_valid),.close_slot(close_slot),.master_error(master_error),
    .control_valid(control_valid),.control_data(control_data),.control_ready(control_ready),.halted(halted),
    .external_fault(1'b0),.contract_fault(contract_fault),.status_valid(status_valid),.status_ready(status_ready),
    .status_word(status_word),.ack_valid(ack_valid),.ack_word(ack_word),.ack_consumed(ack_consumed)
  );
  altpcie_dynamic_control_fetch_v4 #(.READ_CONTROL(1),.DMA_WIDTH(256)) controller (
    .Clk_i(clk),.Rstn_i(rstn),.MsiInterface_i(82'b0),
    .DCSChipSelect_i(cs),.DCSWrite_i(cswrite),.DCSAddress_i(csaddr),.DCSWriteData_i(csdata),
    .DCSByteEnable_i(4'hf),.DCSRead_i(csread),.DCSReadData_o(csreaddata),.DCSWaitRequest_o(cswait),
    .DCMAddress_o(host_address),.DCMWrite_o(host_write),.DCMWriteData_o(host_data),.DCMRead_o(),
    .DCMByteEnable_o(host_be),.DCMWaitRequest_i(host_stall),.DCMReadData_i(32'b0),.DCMReadDataValid_i(1'b0),
    .DTSChipSelect_i(rdcs),.DTSWrite_i(rdwrite),.DTSBurstCount_i(5'd2),.DTSAddress_i(8'd0),
    .DTSWriteData_i(rddata),.DTSWaitRequest_o(rdwait),
    .DmaTxData_o(tx_data),.DmaTxValid_o(tx_valid),.DmaTxReady_i(tx_ready),
    .DmaRxData_i(status_word),.DmaRxValid_i(status_valid),.DmaRxReady_o(status_ready),
    .DmaAckValid_o(ack_valid),.DmaAckData_o(ack_word),.DmaAckConsumed_i(ack_consumed),
    .WrDescTxData_o(),.WrDescTxReq_o(),.WrDescTxAck_i(1'b0),
    .WrDescTxAck_o(forward_ack),.WrDescTxReq_i(forward_req),.WrDescTxData_i(forward_data),
    .WrDescFirstId_i(forward_first),.WrDescFirstId_o(),
    .FetchStatusValid_o(fetch_valid),.FetchStatusData_o(fetch_word),.FetchStatusReady_o(fetch_ready),
    .StatusDiagnosticValid_o(diagnostic_valid),.StatusDiagnosticReady_i(diagnostic_ready),
    .StatusDiagnosticData_o(diagnostic_word),.StatusProtocolFault_o(controller_fault),
    .StatusProtocolFaultWord_o(controller_fault_word),
    .FetchEnable_i(1'b1),.FetchEpoch_i(epoch),.FetchBindValid_i(bind_valid),
    .FetchBindData_i(tx_data),.FetchBindToken_i(descriptor_token),
    .DTSFetchEpoch_i(epoch),.DTSFetchToken_i(rdtoken),.DTSFetchIndex_i(rdindex),
    .WrDTSChipSelect_i(wrcs),.WrDTSWrite_i(wrwrite),.WrDTSWriteData_i(wrdata),.WrDTSWaitRequest_o(wrwait),
    .WrDTSFetchEpoch_i(epoch),.WrDTSFetchToken_i(wrtoken),.WrDTSFetchIndex_i(wrindex),
    .WriteDescValid_o(write_valid),.WriteDescData_o(write_data),.WriteDescReady_i(write_ready),
    .FetchEndValid_i(end_valid),.FetchEndReady_o(end_ready),.FetchEndEpoch_i(epoch),
    .FetchEndToken_i(end_token),.FetchEndError_i(end_error),
    .FetchAbortValid_i(abort_valid),.FetchAbortReady_o(abort_ready),
    .FetchAbortEpoch_i(epoch),.FetchAbortToken_i(abort_token),
    .FetchIssueValid_o(issue_valid),.FetchIssueData_o(issue_data),.FetchIssueFirstId_o(issue_first),
    .FetchFault_o(fetch_fault),.FetchFaultReason_o(fault_reason),.FetchFaultEpoch_o(fault_epoch),
    .FetchFaultToken_o(fault_token),.FetchFaultIndex_o(fault_index),
    .FetchLocalErrorValid_o(local_valid),.FetchLocalErrorReady_i(1'b0),
    .FetchLocalErrorEpoch_o(local_epoch),.FetchLocalErrorToken_o(local_token),
    .FetchLocalErrorReason_o(local_reason),.FetchLocalErrorCount_o(local_count)
  );
  logic [19:0] tokens[256];
  logic [1:0] payload_seen[256];
  bit sealed_seen[256], committed_seen[256], data_seen[128];
  bit host_seen[4];
  int scenario=0, fetches=0, data_tx=0, write_tx=0, host_writes=0, receipts=0, closures=0;
  bit held_tx=0, held_write=0, held_host=0, previous_ack=0, saw_closure=0;
  logic [159:0] held_tx_data, held_write_data;
  logic [99:0] held_host_bus;
  logic [31:0] held_ack;
  function automatic logic [159:0] data_desc(input int id);
    return {6'b0,8'(id),18'd8,64'(32'h900000+id*32),64'(32'h700000+id*32)};
  endfunction
  task automatic tick;
    @(posedge clk); @(negedge clk); #1;
  endtask
  task automatic csr(input logic [7:0] address,input logic [31:0] data);
    csaddr=address; csdata=data; cs=1; cswrite=1; #1;
    while(cswait) tick(); tick(); cs=0; cswrite=0;
  endtask
  task automatic complete(input int id);
    current_valid=1; current_slot=tokens[id][11:8];
    start_valid=1; start_slot=current_slot; tick(); start_valid=0;
    issue_valid_owner=1; issue_slot=current_slot; tick(); issue_valid_owner=0;
    command_valid=1; command_slot=current_slot; return_valid=1; return_slot=current_slot;
    close_valid=1; close_slot=current_slot; tick();
    command_valid=0; return_valid=0; close_valid=0;
    retire_valid=1; retire_slot=current_slot; tick(); retire_valid=0; current_valid=0;
  endtask
  task automatic rdbeat(input int fetch_id,input int ordinal,input int data_id);
    rdcs=1; rdwrite=1; rdtoken=tokens[fetch_id]; rdindex=7'(ordinal); rddata={96'b0,data_desc(data_id)};
    #1; while(rdwait) tick(); tick(); rdcs=0; rdwrite=0;
  endtask
  task automatic wrbeat(input int ordinal,input int data_id);
    wrcs=1; wrwrite=1; wrtoken=tokens[192]; wrindex=7'(ordinal); wrdata={96'b0,data_desc(data_id)};
    #1; while(wrwait) tick(); tick(); wrcs=0; wrwrite=0;
  endtask
  task automatic finish_payload(input int id);
    end_token=tokens[id]; end_error=0; end_valid=1; #1;
    if(!end_ready) $fatal(1,"actual controller refused clean table closure");
    tick(); end_valid=0;
  endtask
  always @(posedge clk) if(rstn) begin : check
    int id;
    if(contract_fault || controller_fault || fetch_fault || local_valid)
      $fatal(1,"actual controller/owner fault owner=%b ctl=%b fetch=%b reason=%0d",contract_fault,controller_fault,fetch_fault,fault_reason);
    if(held_tx && (!tx_valid || tx_data!==held_tx_data)) $fatal(1,"TX lost retained descriptor under stall");
    held_tx=tx_valid&&!tx_ready; if(held_tx) held_tx_data=tx_data;
    if(held_write && (!write_valid || write_data!==held_write_data)) $fatal(1,"write-table copier lost stalled data");
    held_write=write_valid&&!write_ready; if(held_write) held_write_data=write_data;
    if(held_host && {host_write,host_address,host_data,host_be}!=={1'b1,held_host_bus})
      $fatal(1,"host status changed under waitrequest");
    held_host=host_write&&host_stall; if(held_host) held_host_bus={host_address,host_data,host_be};
    if(rdcs && rdwrite && !rdwait) payload_seen[rdtoken[7:0]][rdindex]=1;
    if(wrcs && wrwrite && !wrwait) payload_seen[wrtoken[7:0]][wrindex]=1;
    if(end_valid && end_ready) sealed_seen[end_token[7:0]]=1;
    if(fetch_valid && fetch_ready) begin
      id=int'(fetch_word[7:0]);
      if(payload_seen[id]!==2'b11 || !sealed_seen[id] ||
         {fetch_word[23:16],fetch_word[15:12],fetch_word[7:0]}!==tokens[id])
        $fatal(1,"functional fetch acceptance lacked complete bound table");
      committed_seen[id]=1;
    end
    if(tx_valid && tx_ready) begin
      id=int'(tx_data[153:146]); tokens[id]=descriptor_token;
      if(id>=128) begin
        fetches++;
        if(!issue_valid || issue_data!==tx_data) $fatal(1,"issue capture not physical TX handshake");
        case(id)
          128: if(tx_data[145:128]!=(scenario==2 ? 32 : 16) || tx_data[63:0]!=64'h8200 || issue_first!=0) $fatal(1,"first read-table snapshot wrong");
          129: if(tx_data[145:128]!=(scenario==2 ? 24 : 16) ||
                  tx_data[63:0]!=(scenario==2 ? 64'h8200 : 64'h8240) ||
                  issue_first!=(scenario==2 ? 0 : 2)) $fatal(1,"simultaneous doorbell lost or snapshot advanced incorrectly");
          192: if(tx_data!==forward_data || issue_first!=10 || !forward_ack) $fatal(1,"forwarded fetch mismatch");
          default: $fatal(1,"unexpected fetch ID %0d",id);
        endcase
      end else begin
        if(id>3 || data_seen[id] || tx_data!==data_desc(id) || !committed_seen[id<2 ? 128 : 129])
          $fatal(1,"read FIFO executed unknown, duplicate, or uncommitted descriptor");
        data_seen[id]=1; data_tx++;
      end
    end
    if(write_valid && write_ready) begin
      id=int'(write_data[153:146]);
      if(!committed_seen[192] || id!=10+write_tx || write_data!==data_desc(id))
        $fatal(1,"forwarded table misrouted or reordered");
      write_tx++;
    end
    if(host_write && !host_stall) begin
      if(host_address<64'h8000 || host_address>64'h800c || host_address[1:0]!=0 || host_data!=1 || host_be!=15)
        $fatal(1,"data status ABI or full-ID separation changed");
      id=int'((host_address-64'h8000)>>2);
      if(host_seen[id] || !data_seen[id]) $fatal(1,"duplicate flag or fetch ID aliased a data row");
      host_seen[id]=1;
      host_writes++;
    end
    if(ack_valid && !previous_ack) begin
      receipts++; held_ack=ack_word;
      if(!status_v2_success(ack_word)) $fatal(1,"non-success received ordinary receipt");
      if(ack_word[7] && !committed_seen[ack_word[7:0]]) $fatal(1,"receipt preceded functional commit");
    end
    if(ack_valid && previous_ack && ack_word!==held_ack) $fatal(1,"receipt changed while held");
    if(ack_valid) saw_closure=0;
    if(!ack_valid && ack_consumed && !saw_closure) begin closures++; saw_closure=1; end
    previous_ack=ack_valid;
  end
  initial begin
    if(!$value$plusargs("SCENARIO=%d",scenario)) scenario=0;
    for(int j=0;j<256;j++) begin payload_seen[j]=0; sealed_seen[j]=0; committed_seen[j]=0; tokens[j]=0; end
    for(int j=0;j<128;j++) data_seen[j]=0;
    for(int j=0;j<4;j++) host_seen[j]=0;
    repeat(4) tick(); rstn=1; tick();
    csr(8'h00,32'h8000); csr(8'h04,0); csr(8'h0c,0); csr(8'h08,32'h1000);
    if(scenario==2) csr(8'h14,3);
    csr(8'h10,scenario==2 ? 3 : 1); wait(tx_valid); admission_enable=0;
    repeat(7) begin tick(); if(fetches!=0 || tx_data[153:146]!=128)
      $fatal(1,"held fetch was accepted or counter advanced without ready"); end
    if(scenario==1) begin
      admission_enable=1; wait(fetches==1); tick();
      rdbeat(128,0,0);
      current_valid=1; current_slot=tokens[128][11:8]; start_slot=current_slot; start_valid=1;
      tick(); start_valid=0; master_error=1; tick(); master_error=0;
      wait(diagnostic_valid); repeat(9) begin tick();
        if(!diagnostic_valid || diagnostic_word[7:0]!=128 || diagnostic_word[27:24]!=DMA_CAUSE_MASTER ||
           ack_valid || data_tx!=0 || host_writes!=0 || write_valid)
          $fatal(1,"actual partial-table error escaped retained diagnostic path"); end
      diagnostic_ready=1; tick(); diagnostic_ready=0;
      rdbeat(128,1,1); finish_payload(128); repeat(9) tick();
      if(data_tx || ack_valid || host_writes) $fatal(1,"failed table later became executable");
    end else if(scenario==2) begin
      // Table-last holds a saved pending pointer. A fresh external doorbell
      // wins on the first ACK edge after old TX clears the table-last flag.
      csr(8'h10,1);
      cs=1; cswrite=1; csaddr=8'h10; csdata=2; tick();
      admission_enable=1; tick();
      if(cswait) $fatal(1,"doorbell incorrectly stalled behind saved pending pointer");
      tick(); cs=0; cswrite=0;
      wait(fetches==2); repeat(10) tick();
      if(fetches!=2 || tx_valid) $fatal(1,"superseded saved pending pointer replayed");
    end else if(scenario==3) begin
      admission_enable=1; wait(fetches==1); tick();
      forward_data={6'b0,8'd192,18'd16,64'hc000,64'hb200}; forward_first=10; forward_req=1;
      #1; while(!forward_ack) tick(); tick(); forward_req=0;
      complete(128); rdbeat(128,0,0); rdbeat(128,1,1);
      admission_enable=0; finish_payload(128);
      // ID192 remains reserved without completion. A new held request for that
      // ID must not monopolize TX and prevent the committed read FIFO draining.
      forward_req=1; wait(tx_valid && !tx_data[153]); repeat(7) tick();
      admission_enable=1; wait(data_tx==2 && closures==1); repeat(7) tick();
      if(fetches!=2 || forward_ack || data_tx!=2 || !forward_req)
        $fatal(1,"credit-blocked fetch monopolized TX or reused a live ID");
    end else begin
      // Accept a new doorbell on the exact edge accepting the old immutable TX.
      cs=1; cswrite=1; csaddr=8'h10; csdata=3; #1; while(cswait) tick();
      admission_enable=1; tick(); cs=0; cswrite=0;
      wait(fetches==2); tick();
      forward_data={6'b0,8'd192,18'd16,64'hc000,64'hb200}; forward_first=10; forward_req=1;
      #1; while(!forward_ack) tick(); tick(); forward_req=0;
      if(fetches!=3) $fatal(1,"forwarded request not accepted exactly once");
      complete(128); complete(129); complete(192); wait(fetch_valid);
      fork rdbeat(128,1,1); wrbeat(0,10); join
      wrbeat(1,11); finish_payload(192); rdbeat(129,0,2);
      repeat(5) tick(); rdbeat(129,1,3); finish_payload(129);
      repeat(7) begin tick(); if(fetch_ready || data_tx || write_valid || receipts)
        $fatal(1,"early completion released an incomplete first table"); end
      rdbeat(128,0,0); repeat(5) begin tick(); if(fetch_ready || data_tx)
        $fatal(1,"table bypassed explicit producer closure"); end
      admission_enable=0; finish_payload(128); wait(tx_valid && !tx_data[153]);
      repeat(9) tick(); wait(write_valid); repeat(7) tick();
      if(data_tx!=0 || write_tx!=0) $fatal(1,"stalled destination accepted a descriptor");
      write_ready=1; admission_enable=1; wait(data_tx==4 && write_tx==2 && closures==3); tick();
      for(int j=0;j<4;j++) complete(j);
      wait(host_write); repeat(9) begin tick(); if(host_writes) $fatal(1,"stalled status published"); end
      host_stall=0; wait(host_writes==4 && closures==7); repeat(4) tick();
      if(receipts!=7 || ack_valid || ack_consumed || diagnostic_valid)
        $fatal(1,"actual controller did not close all seven receipts");
    end
    $display("PASS actual_controller_fetch_v4 scenario=%0d fetches=%0d read_data=%0d write_data=%0d receipts=%0d closures=%0d",scenario,fetches,data_tx,write_tx,receipts,closures);
    $finish;
  end
endmodule
