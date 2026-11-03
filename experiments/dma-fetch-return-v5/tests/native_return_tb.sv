// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
// Real generated producer/owner, native Quartus FIFOs, real route/consumer/sink.
// Only host completions and destination acceptance are testbench endpoints.
// Explicit boundary corruption muxes are used solely by negative scenarios.
module native_return_tb;
  import dma_status_v2_pkg::*;
  logic clk=0, rstn=0, enable=0;
  always #5 clk=~clk;
  logic [31:0] epoch=32'h51001;
  logic descriptor_valid=0, issue_valid=0, issue_offer=0;
  logic [159:0] descriptor=0, issue_desc=0;
  logic [7:0] issue_first=0;
  wire descriptor_ready, issue_ready;
  logic master_enable=1, grant_enable=1, control_load=0;
  logic [31:0] control_data=0;
  wire control_ready, contract_fault, arb, tx_push, rx_pop, tag_pop;
  wire [259:0] tx;
  wire [31:0] engine_status_word, unused_dma_status;
  wire engine_status_valid, engine_status_ready, ack_valid, ack_consumed;
  wire [31:0] ack_word;
  wire engine_write, engine_wait;
  wire [63:0] engine_address, return_base;
  wire [255:0] engine_data;
  wire [31:0] engine_be, return_epoch;
  wire [4:0] engine_burst;
  wire [19:0] return_token, bind_token;
  wire [7:0] return_count;
  wire bind_valid;
  wire [159:0] bind_desc;
  wire end_valid, end_ready, end_error;
  wire [31:0] end_epoch;
  wire [19:0] end_token;
  wire producer_fault;
  wire [31:0] producer_fault_epoch;
  wire [19:0] producer_fault_token;
  wire [7:0] producer_fault_reason, producer_fault_tag;
  // Declare feedback nets before the native producer instance: no implicit nets.
  wire route_fault_now, consumer_fault;
  logic replay_status=0;

  typedef struct {
    logic [159:0] desc;
    logic [19:0] token;
    logic [31:0] epoch, success_word;
    int first, count, issued_dw, returned_dw, accepted, emitted, last_accept_cycle;
    logic [127:0] seen;
    logic [3:0] cause;
    bit reserved, admitted, error, sealed, committed, receipt_closed;
  } owner_t;
  typedef struct {
    int owner, offset_dw, words, supplied;
    logic [7:0] tag;
    logic [63:0] address;
  } request_t;
  owner_t owners[$];
  request_t requests[$];
  logic [265:0] packets[$];
  int packet_owner[$], packet_words[$];
  int consumed=0, cycles=0, accepted_total=0, emitted_total=0;
  int closed_total=0, receipts=0, host_flags=0, diagnostics=0;
  logic [265:0] rx;
  logic [3:0] rx_count;
  // Present the queued FIFO head before the next sampling edge. Native queue
  // mutation does not reliably trigger an implicit combinational sensitivity.
  always @(negedge clk) begin
    rx=consumed<packets.size() ? packets[consumed] : 266'b0;
    rx_count=consumed<packets.size() ? 4'd1 : 4'd0;
  end

  altpcieav_dma_rd_fetch_return_v5 #(
    .DMA_WIDTH(256),.DMA_BE_WIDTH(32),.DMA_BRST_CNT_W(5),
    .RDDMA_AVL_ADDR_WIDTH(64),.DEVICE_FAMILY("Arria 10")
  ) producer (
    .Clk_i(clk),.Rstn_i(rstn),.FetchEnable_i(enable),.FetchEpoch_i(epoch),
    .RdDmaWrite_o(engine_write),.RdDmaAddress_o(engine_address),
    .RdDmaWriteData_o(engine_data),.RdDmaWriteEnable_o(engine_be),
    .RdDmaBurstCount_o(engine_burst),.RdDmaWaitRequest_i(engine_wait),
    .ReturnEpoch_o(return_epoch),.ReturnToken_o(return_token),
    .ReturnBase_o(return_base),.ReturnCount_o(return_count),
    .RdDmaRxData_i(descriptor),.RdDmaRxValid_i(descriptor_valid),
    .RdDmaRxReady_o(descriptor_ready),.FetchBindValid_o(bind_valid),
    .FetchBindData_o(bind_desc),.FetchBindToken_o(bind_token),
    .FetchEndValid_o(end_valid),.FetchEndReady_i(end_ready),
    .FetchEndEpoch_o(end_epoch),.FetchEndToken_o(end_token),.FetchEndError_o(end_error),
    .ReturnRouteFault_i(route_fault_now || consumer_fault),
    .ReturnFault_o(producer_fault),.ReturnFaultEpoch_o(producer_fault_epoch),
    .ReturnFaultToken_o(producer_fault_token),.ReturnFaultReason_o(producer_fault_reason),
    .ReturnFaultTag_o(producer_fault_tag),
    .RdDmaTxData_o(engine_status_word),.RdDmaTxValid_o(engine_status_valid),
    .RdDmaTxReady_i(engine_status_ready),.RdDmaAckValid_i(ack_valid),
    .RdDmaAckData_i(ack_word),.RdDmaAckConsumed_o(ack_consumed),
    .RxFifoRdReq_o(rx_pop),.RxFifoDataq_i(rx),.RxFifoCount_i(rx_count),
    .PreDecodeTagRdReq_o(tag_pop),.PreDecodeTag_i(rx[79:72]),
    .PreDecodeTagCount_i(rx_count),.TxFifoWrReq_o(tx_push),.TxFifoData_o(tx),
    .TxFifoCount_i(4'd0),.RdDMACntrlLoad_i(control_load),.RdDMACntrlData_i(control_data),
    .RdDMACntrlReady_o(control_ready),.RdDMAStatus_o(unused_dma_status),
    .ContractFault_o(contract_fault),.RdDMmaArbReq_o(arb),
    .RdDMmaArbGranted_i(arb && grant_enable),.BusDev_i(13'h100),
    .DevCsr_i(32'd0),.MasterEnable_i(master_enable),
    .ko_cpl_spc_header(8'hff),.ko_cpl_spc_data(12'hfff)
  );

  logic inject_route=0, inject_base=0, inject_index=0, inject_epoch=0;
  logic [31:0] stale_epoch=0;
  wire [19:0] routed_token=return_token ^ (inject_route ? 20'h00040 : 20'd0);
  wire [63:0] routed_base=return_base+(inject_base ? 64'd32 : 64'd0);
  wire [31:0] routed_epoch=inject_epoch ? stale_epoch : return_epoch;
  wire payload_write, route_accept, route_busy;
  wire [63:0] payload_address, beat_address;
  wire [255:0] payload_data;
  wire [31:0] payload_be;
  wire [4:0] payload_burst;
  logic payload_stall=0;
  wire [1:0] dts_write, dts_wait;
  wire [1:0][255:0] dts_data;
  wire [1:0][31:0] dts_epoch;
  wire [1:0][19:0] dts_token;
  wire [1:0][6:0] dts_index;
  wire route_fault;
  wire [7:0] route_reason, route_reason_now;
  wire [31:0] route_fault_epoch;
  wire [19:0] route_fault_token;
  wire [63:0] route_fault_address;
  dma_fetch_return_route_v5 route (
    .clk(clk),.rstn(rstn),.enable(enable),.epoch(epoch),
    .inhibit(producer_fault || consumer_fault),
    .s_address(engine_address),.s_write(engine_write),.s_data(engine_data),
    .s_byteenable(engine_be),.s_burstcount(engine_burst),
    .s_epoch(routed_epoch),.s_token(routed_token),.s_base(routed_base),.s_count(return_count),
    .s_waitrequest(engine_wait),.payload_address(payload_address),.payload_write(payload_write),
    .payload_data(payload_data),.payload_byteenable(payload_be),.payload_burstcount(payload_burst),
    .payload_waitrequest(payload_stall),.dts_write(dts_write),.dts_data(dts_data),
    .dts_epoch(dts_epoch),.dts_token(dts_token),.dts_index(dts_index),.dts_waitrequest(dts_wait),
    .fault_now(route_fault_now),.fault(route_fault),.fault_reason(route_reason),
    .fault_epoch(route_fault_epoch),.fault_token(route_fault_token),.fault_address(route_fault_address),
    .reason_now(route_reason_now),.beat_address(beat_address),.accept(route_accept),.busy(route_busy)
  );

  logic allow_status=0, allow_commit=1, allow_end=1, emit_ready=0, diagnostic_ready=0, local_ready=0;
  logic stop_last_read=0, turn=0;
  wire pick_write=dts_write[1] && (!dts_write[0] || turn);
  wire destination_stall=stop_last_read && !pick_write && dts_index[0]==7;
  wire payload_ready, core_end_ready, core_status_ready;
  wire core_payload_valid=(|dts_write) && !destination_stall;
  assign dts_wait[0]=pick_write || destination_stall || !payload_ready;
  assign dts_wait[1]=!pick_write || destination_stall || !payload_ready;
  always @(posedge clk or negedge rstn)
    if(!rstn) turn<=0;
    else if(core_payload_valid && payload_ready) turn<=!pick_write;
  assign end_ready=core_end_ready && allow_end;
  wire sink_ready, fetch_valid, sink_diag_valid, sink_fault;
  wire [31:0] fetch_word, sink_diag_word, sink_fault_word;
  wire host_write;
  wire [63:0] host_address;
  wire [31:0] host_data;
  wire [3:0] host_be;
  logic host_stall=0;
  assign engine_status_ready=sink_ready && allow_status;
  dma_status_sink_fetch_v4 status_sink (
    .clk(clk),.rstn(rstn),.s_valid(engine_status_valid && allow_status),.s_ready(sink_ready),
    .s_word(engine_status_word),.s_msi(1'b0),.header_base(64'h100000),.msi_interface(82'd0),
    .dcm_write(host_write),.dcm_address(host_address),.dcm_data(host_data),
    .dcm_byteenable(host_be),.dcm_waitrequest(host_stall),
    .fetch_valid(fetch_valid),.fetch_ready(core_status_ready && allow_commit && !replay_status),.fetch_word(fetch_word),
    .diagnostic_valid(sink_diag_valid),.diagnostic_ready(core_status_ready && allow_commit && !replay_status),
    .diagnostic_word(sink_diag_word),.retired_ack_valid(ack_valid),.retired_ack_word(ack_word),
    .retired_ack_consumed(ack_consumed),.protocol_fault(sink_fault),.fault_word(sink_fault_word)
  );
  logic [31:0] replay_word=0;
  wire status_valid=replay_status || (allow_commit && (fetch_valid || sink_diag_valid));
  wire [31:0] status_word=replay_status ? replay_word : fetch_valid ? fetch_word : sink_diag_word;
  wire emit_valid, emit_write, diagnostic_valid, local_valid;
  wire [159:0] emit_data;
  wire [31:0] diagnostic_word, fault_epoch, local_epoch;
  wire [19:0] fault_token, local_token;
  wire [7:0] fault_reason, fault_index, local_reason, local_count;
  wire fabric_fault=route_fault_now || producer_fault;
  wire [7:0] fabric_reason=route_fault_now ? (8'h40|route_reason_now) : (8'h80|producer_fault_reason);
  wire [31:0] fabric_epoch=route_fault_now ? route_fault_epoch : producer_fault_epoch;
  wire [19:0] fabric_token=route_fault_now ? route_fault_token : producer_fault_token;
  wire [7:0] fabric_index=route_fault_now ? {1'b0,dts_index[pick_write]} : producer_fault_tag;
  dma_fetch_commit_return_v5 consumer (
    .clk(clk),.rstn(rstn),.enable(enable),.epoch(epoch),
    .issue_offer(issue_offer),.issue_valid(issue_valid),.issue_ready(issue_ready),
    .issue_desc(issue_desc),.issue_first(issue_first),
    .bind_valid(bind_valid),.bind_desc(bind_desc),.bind_token(bind_token),
    .payload_valid(core_payload_valid),.payload_ready(payload_ready),.payload_write_table(pick_write),
    .payload_epoch(dts_epoch[pick_write]),.payload_token(dts_token[pick_write]),
    .payload_index(dts_index[pick_write] ^ (inject_index ? 7'd1 : 7'd0)),
    .payload_data(dts_data[pick_write][159:0]),
    .end_valid(end_valid && allow_end),.end_ready(core_end_ready),
    .end_epoch(end_epoch),.end_token(end_token),.end_error(end_error),
    .abort_valid(1'b0),.abort_ready(),.abort_epoch(32'd0),.abort_token(20'd0),
    .status_valid(status_valid),.status_ready(core_status_ready),.status_word(status_word),
    .ack_valid(ack_valid),.ack_consumed(ack_consumed),.ack_word(ack_word),
    .emit_valid(emit_valid),.emit_ready(emit_ready),.emit_write_table(emit_write),.emit_data(emit_data),
    .diagnostic_valid(diagnostic_valid),.diagnostic_ready(diagnostic_ready),.diagnostic_word(diagnostic_word),
    .local_error_valid(local_valid),.local_error_ready(local_ready),.local_error_epoch(local_epoch),
    .local_error_token(local_token),.local_error_reason(local_reason),.local_error_count(local_count),
    .fault(consumer_fault),.fault_reason(fault_reason),.fault_epoch(fault_epoch),.fault_token(fault_token),
    .fault_index(fault_index),.fabric_fault(fabric_fault),.fabric_reason(fabric_reason),
    .fabric_epoch(fabric_epoch),.fabric_token(fabric_token),.fabric_index(fabric_index)
  );

  function automatic logic [159:0] executable(input int o,input int ordinal);
    return {6'd0,8'(owners[o].first+ordinal),18'd8,
            64'(32'h400000+o*4096+ordinal*32),64'(32'h200000+o*4096+ordinal*32)};
  endfunction
  function automatic logic [31:0] host_word(input int o,input int word_offset);
    logic [255:0] value;
    if(owners[o].desc[153]) begin
      value={96'hace051005100aabbccddeeff,executable(o,word_offset/8)};
      return value[(word_offset%8)*32 +: 32];
    end
    return 32'hcafe0000+32'(o*4096+word_offset);
  endfunction
  function automatic int find_token(input logic [19:0] tok,input logic [31:0] ep);
    int found=-1;
    // Finite generation legitimately recurs after release. Admission below
    // checks the prior custody before making this newest match authoritative.
    foreach(owners[k]) if(owners[k].admitted && owners[k].token==tok && owners[k].epoch==ep) found=k;
    return found;
  endfunction
  task automatic tick;
    @(posedge clk); @(negedge clk); #1;
  endtask
  task automatic reset_fenced;
    // Test environment provides this fence: no host packet or receipt survives.
    // Hardware must establish its own transport fence before using reset/epoch.
    rstn=0; enable=0; descriptor_valid=0; issue_valid=0; issue_offer=0;
    repeat(4) tick(); rstn=1; enable=1; repeat(80) tick();
  endtask
  task automatic add_owner(input int id,input int count,input int first,output int o);
    owner_t record;
    record='{default:'0}; record.first=first; record.count=count;
    record.epoch=epoch; record.last_accept_cycle=-1;
    record.desc={6'd0,8'(id),18'(count*8),
      id>=192 ? 64'h80002200 : id>=128 ? 64'h80000100 : 64'h180000,
      64'(4096*(owners.size()+1))};
    o=owners.size(); owners.push_back(record);
    if(id>=128) begin
      issue_desc=record.desc; issue_first=8'(first); issue_valid=1; issue_offer=1;
      #1; while(!issue_ready) tick(); tick(); issue_valid=0; issue_offer=0;
    end
    descriptor=record.desc; descriptor_valid=1;
    #1; while(!descriptor_ready) tick(); tick(); descriptor_valid=0;
  endtask
  task automatic completion(input int r,input int words,input bit replay=0);
    int base, nbeats, off, position, o;
    logic [265:0] zero='0;
    @(negedge clk); #1;
    o=requests[r].owner; off=replay ? 0 : requests[r].supplied;
    if(words<1 || off+words>requests[r].words || words%8!=0)
      $fatal(1,"invalid test completion fragment");
    base=packets.size(); nbeats=(4+words+7)/8;
    repeat(nbeats) begin packets.push_back(zero); packet_owner.push_back(o); packet_words.push_back(0); end
    packets[base][31:0]=32'h4a000000|32'(words);
    packets[base][63:32]=32'((requests[r].words-off)*4);
    packets[base][95:64]={16'h0800,requests[r].tag,1'b0,7'(requests[r].address+off*4)};
    packets[base][256]=1;
    for(int w=0;w<words;w++) begin
      position=w+4;
      packets[base+position/8][(position%8)*32 +: 32]=host_word(o,requests[r].offset_dw+off+w);
    end
    packets[base+nbeats-1][257]=1;
    packets[base+nbeats-1][259:258]=2'd2;
    packet_words[base+nbeats-1]=words;
    if(!replay) requests[r].supplied+=words;
  endtask
  task automatic command(input logic [31:0] value);
    control_load=1; control_data=value; #1;
    while(!control_ready) tick(); tick(); control_load=0; control_data=0;
  endtask
  task automatic finish(input string name);
    $display("PASS native-return-v5 %s requests=%0d accepted=%0d emits=%0d closes=%0d receipts=%0d",
      name,requests.size(),accepted_total,emitted_total,closed_total,receipts);
    $finish;
  endtask
  task automatic complete_one(input int o,input int first_request);
    wait(requests.size()>first_request);
    completion(first_request,requests[first_request].words);
    wait(owners[o].receipt_closed && owners[o].emitted==owners[o].count);
    tick();
  endtask

  bit expect_fault=0, held_engine=0, held_end=0, held_emit=0, held_status=0;
  logic [480:0] held_engine_bus;
  logic [52:0] held_end_bus;
  logic [160:0] held_emit_bus;
  logic [31:0] held_status_bus;
  int burst_position=0, receipt_owner=-1;
  bit receipt_seen_consumed=0;
  always @(posedge clk) begin : monitor
    int o, ordinal, found;
    logic [63:0] effective, source;
    request_t request;
    cycles++;
    if(!rstn) begin
      held_engine=0; held_end=0; held_emit=0; held_status=0;
      burst_position=0; receipt_owner=-1; receipt_seen_consumed=0;
    end else begin
      if(!expect_fault && (producer_fault || contract_fault || route_fault_now || consumer_fault || sink_fault))
        $fatal(1,"unexpected fault producer=%b route=%h consumer=%h sink=%b",producer_fault,route_reason_now,fault_reason,sink_fault);
      if(issue_valid && issue_ready) begin
        found=-1;
        foreach(owners[k]) if(owners[k].desc==issue_desc && !owners[k].admitted) found=k;
        if(found<0 || owners[found].reserved) $fatal(1,"unknown or duplicate bank reservation");
        // The real consumer refuses a same-ID issue until its old bank, copier
        // and four-phase receipt have released; this is an observed handshake.
        owners[found].reserved=1;
      end
      if(descriptor_valid && descriptor_ready) begin
        found=-1;
        foreach(owners[k]) if(owners[k].desc==descriptor && !owners[k].admitted) found=k;
        if(found<0 || bind_valid!==descriptor[153] || bind_desc!==descriptor ||
           (descriptor[153] && !owners[found].reserved))
          $fatal(1,"admission/bind mismatch");
        foreach(owners[k]) if(owners[k].admitted && owners[k].token==bind_token && owners[k].epoch==epoch)
          if(!owners[k].receipt_closed || (owners[k].desc[153] && owners[k].emitted!=owners[k].count))
            $fatal(1,"finite token recurred before old receipt/copier custody released");
        owners[found].admitted=1; owners[found].token=bind_token;
      end
      if(tx_push) begin
        if($isunknown(tx) || tx[31:24]!=8'h00 || tx[9:0]==0 || tx[9:0]>32)
          $fatal(1,"unexpected native MRd %h",tx);
        source={32'd0,tx[95:64]}; found=-1;
        foreach(owners[k]) if(owners[k].admitted && owners[k].epoch==epoch &&
            source>=owners[k].desc[63:0] && source<owners[k].desc[63:0]+owners[k].count*32) found=k;
        if(found<0) $fatal(1,"MRd without actual admitted descriptor");
        request.owner=found; request.offset_dw=int'((source-owners[found].desc[63:0])>>2);
        request.words=int'(tx[9:0]); request.supplied=0; request.tag=tx[47:40]; request.address=source;
        requests.push_back(request); owners[found].issued_dw+=request.words;
      end
      if(rx_pop) begin
        if(consumed>=packets.size()) $fatal(1,"native RX underflow");
        if(packet_words[consumed]!=0) owners[packet_owner[consumed]].returned_dw+=packet_words[consumed];
        consumed<=consumed+1;
      end
      if(held_engine && {engine_write,engine_address,engine_data,engine_be,engine_burst,
          return_epoch,return_token,return_base,return_count}!=={1'b1,held_engine_bus})
        $fatal(1,"engine data or immutable identity changed under waitrequest");
      held_engine=engine_write && engine_wait;
      if(held_engine) held_engine_bus={engine_address,engine_data,engine_be,engine_burst,return_epoch,return_token,return_base,return_count};
      if(route_accept !== ((payload_write && !payload_stall) || (|(dts_write & ~dts_wait))))
        $fatal(1,"producer acceptance did not equal selected destination acceptance");
      if(engine_write && !engine_wait) begin
        effective=engine_address+64'(32*burst_position);
        o=find_token(return_token,return_epoch);
        if(o<0 || beat_address!==effective || return_base!==owners[o].desc[127:64])
          $fatal(1,"native return lost immutable admission metadata");
        if(owners[o].desc[153] && return_count!=owners[o].count) $fatal(1,"table span metadata changed");
        if(effective<owners[o].desc[127:64] || (effective-owners[o].desc[127:64])%32!=0)
          $fatal(1,"bad accepted return address");
        ordinal=int'((effective-owners[o].desc[127:64])>>5);
        if(ordinal>=owners[o].count || owners[o].seen[ordinal] || engine_be!==32'hffffffff)
          $fatal(1,"duplicate/out-of-span/partial destination beat");
        for(int w=0;w<8;w++) if(engine_data[w*32 +: 32]!==host_word(o,ordinal*8+w))
          $fatal(1,"native payload mismatch owner=%0d ordinal=%0d word=%0d",o,ordinal,w);
        if(owners[o].desc[153]) begin
          if(dts_token[pick_write]!==owners[o].token || dts_epoch[pick_write]!==owners[o].epoch ||
             dts_index[pick_write]!=ordinal || pick_write!==owners[o].token[6])
            $fatal(1,"DTS route/ordinal differs from admitted base plus accepted address");
        end else if(!payload_write || payload_data!==engine_data || payload_address!==engine_address ||
                    payload_be!==engine_be || payload_burst!==engine_burst)
          $fatal(1,"ordinary H2D payload path changed");
        owners[o].seen[ordinal]=1; owners[o].accepted++; owners[o].last_accept_cycle=cycles;
        accepted_total++;
        burst_position=burst_position+1==engine_burst ? 0 : burst_position+1;
      end
      if(held_end && (!end_valid || {end_epoch,end_token,end_error}!==held_end_bus))
        $fatal(1,"retained producer close changed");
      held_end=end_valid && !end_ready;
      if(held_end) held_end_bus={end_epoch,end_token,end_error};
      if(end_valid) begin
        o=find_token(end_token,end_epoch);
        if(o<0 || !owners[o].desc[153] || owners[o].sealed ||
           owners[o].returned_dw!=owners[o].issued_dw || owners[o].accepted*8!=owners[o].issued_dw ||
           owners[o].last_accept_cycle>=cycles || end_error!==owners[o].error ||
           (!end_error && owners[o].issued_dw!=owners[o].count*8))
          $fatal(1,"producer close precedes token settlement/last destination or changes cause");
        if(end_ready) begin owners[o].sealed=1; closed_total++; end
      end
      if(held_status && (!engine_status_valid || engine_status_word!==held_status_bus))
        $fatal(1,"owner status changed while backpressured");
      held_status=engine_status_valid && !engine_status_ready;
      if(held_status) held_status_bus=engine_status_word;
      if(engine_status_valid && engine_status_ready) begin
        o=find_token({engine_status_word[23:16],engine_status_word[15:12],engine_status_word[7:0]},epoch);
        if(o<0 || !status_v2_valid(engine_status_word)) $fatal(1,"owner status identity invalid");
        if(status_v2_success(engine_status_word)) owners[o].success_word=engine_status_word;
        else if(engine_status_word[27:24]!==owners[o].cause) $fatal(1,"owner error cause changed");
      end
      if(status_valid && core_status_ready && status_v2_success(status_word)) begin
        o=find_token({status_word[23:16],status_word[15:12],status_word[7:0]},epoch);
        if(o<0 || !owners[o].sealed || owners[o].error || owners[o].accepted!=owners[o].count || owners[o].committed)
          $fatal(1,"whole-table executable commit is premature or duplicated");
        owners[o].committed=1;
      end
      if(held_emit && (!emit_valid || {emit_write,emit_data}!==held_emit_bus)) $fatal(1,"stalled copier changed");
      held_emit=emit_valid && !emit_ready;
      if(held_emit) held_emit_bus={emit_write,emit_data};
      if(emit_valid && emit_ready) begin
        found=-1;
        foreach(owners[k]) if(owners[k].desc[153] && owners[k].emitted<owners[k].count &&
          emit_data===executable(k,owners[k].emitted)) found=k;
        if(found<0 || !owners[found].committed || emit_write!==owners[found].token[6])
          $fatal(1,"uncommitted/reordered/unknown executable descriptor");
        owners[found].emitted++; emitted_total++;
      end
      if(ack_valid && receipt_owner<0) begin
        receipt_owner=find_token({ack_word[23:16],ack_word[15:12],ack_word[7:0]},epoch);
        if(receipt_owner<0 || !status_v2_success(ack_word) || owners[receipt_owner].receipt_closed ||
           (ack_word[7] && !owners[receipt_owner].committed)) $fatal(1,"receipt lacks committed owner");
      end
      if(ack_valid && ack_consumed) receipt_seen_consumed=1;
      if(receipt_owner>=0 && receipt_seen_consumed && !ack_valid && !ack_consumed) begin
        owners[receipt_owner].receipt_closed=1; receipts++; receipt_owner=-1; receipt_seen_consumed=0;
      end
      if(host_write && !host_stall) begin
        if(host_data!==32'd1 || host_be!==4'hf || host_address!==64'h10001c)
          $fatal(1,"ordinary payload success publication changed");
        host_flags++;
      end
      if(diagnostic_valid && diagnostic_ready) diagnostics++;
    end
  end

  int scenario=0;
  initial begin : stimulus
    int a,b,c,r,n;
    logic [19:0] old_token;
    if(!$value$plusargs("SCENARIO=%d",scenario)) scenario=0;
    reset_fenced();
    case(scenario)
      0: begin
        allow_end=0; stop_last_read=1;
        add_owner(128,8,0,a); add_owner(192,8,32,b); add_owner(7,8,0,c);
        wait(requests.size()==6);
        // Close the write table while read and ordinary payload tags remain live.
        completion(3,16); completion(2,16); completion(3,16); completion(2,16);
        wait(end_valid); if(end_token!==owners[b].token || owners[a].accepted!=0)
          $fatal(1,"per-owner close waited for unrelated returns");
        repeat(5) tick(); allow_end=1; wait(owners[b].sealed);
        payload_stall=1;
        completion(0,16); completion(4,16); completion(1,16); completion(4,16);
        completion(0,16); completion(5,32); completion(1,16);
        wait(payload_write); repeat(5) tick(); payload_stall=0;
        wait(dts_write[0] && dts_index[0]==7);
        repeat(7) begin tick(); if(owners[a].sealed || owners[a].accepted!=7 || emitted_total!=0)
          $fatal(1,"last-DTS stall did not retain producer debt"); end
        stop_last_read=0; wait(owners[a].sealed);
        if(emitted_total || owners[a].committed || owners[b].committed)
          $fatal(1,"table executed without owner success");
        allow_status=1; wait(emit_valid); repeat(5) tick(); emit_ready=1;
        wait(receipts==3 && emitted_total==16 && host_flags==1); tick();
        old_token=owners[a].token; r=requests.size(); add_owner(128,2,16,n); complete_one(n,r);
        if(owners[n].token==old_token) $fatal(1,"reuse repeated immutable owner identity");
        finish("mixed_interleaved_split_backpressure_reuse");
      end
      1,2: begin
        allow_status=1; r=requests.size(); add_owner(128,8,0,a);
        wait(requests.size()==r+1); @(negedge clk); #1; grant_enable=0;
        owners[a].error=1; owners[a].cause=scenario==1 ? DMA_CAUSE_MASTER : DMA_CAUSE_ABORT;
        if(scenario==1) master_enable=0; else command(32'd4);
        wait(diagnostic_valid);
        if(owners[a].sealed || owners[a].accepted!=0 || diagnostic_word[27:24]!=owners[a].cause)
          $fatal(1,"early error diagnostic lost cause or fabricated settlement");
        repeat(5) tick(); completion(r,32);
        wait(local_valid && owners[a].sealed);
        if(local_token!==owners[a].token || local_epoch!==epoch || local_reason!=1 || local_count!=4 ||
           emitted_total || ack_valid || requests.size()!=r+1) $fatal(1,"partial-error close/poison invalid");
        diagnostic_ready=1; local_ready=1; repeat(5) tick();
        descriptor=owners[a].desc; descriptor_valid=1;
        repeat(5) begin tick(); if(descriptor_ready) $fatal(1,"error owner was reused"); end
        descriptor_valid=0; finish(scenario==1 ? "master_partial_drain" : "abort_partial_drain");
      end
      3,4,5,10: begin
        add_owner(128,2,0,a); wait(requests.size()==1);
        expect_fault=1; inject_route=scenario==3; inject_base=scenario==4;
        inject_index=scenario==5; inject_epoch=scenario==10; stale_epoch=epoch-1;
        completion(0,16); wait(consumer_fault); tick();
        if(accepted_total || emitted_total || closed_total || ack_valid)
          $fatal(1,"invalid route/ordinal/epoch was accepted");
        if(scenario==3 && route_reason!=6) $fatal(1,"wrong route was not classified");
        if(scenario==4 && route_reason!=7) $fatal(1,"wrong ordinal base was not classified");
        if(scenario==5 && fault_reason!=3) $fatal(1,"wrong DTS ordinal was not classified");
        if(scenario==10 && route_reason!=5) $fatal(1,"stale return epoch was not classified");
        finish("invalid_route_ordinal_epoch_quarantine");
      end
      6: begin
        allow_status=1; emit_ready=1; add_owner(128,1,0,a); complete_one(a,0);
        replay_word=owners[a].success_word; expect_fault=1; replay_status=1;
        wait(consumer_fault); tick();
        if(fault_reason!=5 || emitted_total!=1 || receipts!=1) $fatal(1,"late status replay escaped quarantine");
        finish("late_status");
      end
      7: begin
        allow_status=1; allow_commit=0;
        add_owner(128,1,0,a); wait(requests.size()==1); completion(0,8);
        wait(owners[a].sealed && fetch_valid); expect_fault=1;
        // Hold the real sink's success at its consumer boundary, then expose
        // it on exactly the cycle a replayed native packet faults the producer.
        completion(0,8,1);
        // The queue-backed FIFO presents a new head on the falling edge.
        // Release success only once that real replay header is visible,
        // before the common rising-edge acceptance opportunity.
        @(negedge clk); #1;
        if(rx_count==0 || !rx[256] || !fetch_valid || !producer_fault)
          $fatal(1,"late payload/status collision was not presented");
        allow_commit=1;
        wait(consumer_fault); tick();
        if(!producer_fault || emitted_total || owners[a].committed || ack_valid)
          $fatal(1,"late payload/status race committed stale table");
        finish("late_payload_same_edge_status_veto");
      end
      8: begin
        allow_status=1; emit_ready=1;
        // Exercise legal ff->1 recurrence at the same slot and full ID.
        // complete_one waits for this owner's receipt AND copier; add_owner
        // observes a fresh same-ID consumer reservation before every admission.
        for(int lifecycle=0;lifecycle<260;lifecycle++) begin
          r=requests.size(); add_owner(128,1,0,a); complete_one(a,r);
          if(lifecycle==0) old_token=owners[a].token;
          if(owners[a].token[11:8]!=0 || owners[a].token[19:12]!=8'((lifecycle%255)+1))
            $fatal(1,"ordinary slot/generation recurrence changed");
          if(lifecycle==254 && owners[a].token[19:12]!=255) $fatal(1,"generation boundary missed");
          if(lifecycle==255 && owners[a].token!==old_token) $fatal(1,"full-token recurrence was not exercised");
        end
        finish("full_token_recurrence260");
      end
      9: begin
        allow_status=1; emit_ready=1; add_owner(128,1,0,a); complete_one(a,0);
        if(consumed!=packets.size() || route_busy || ack_valid || ack_consumed)
          $fatal(1,"test reset attempted without transport/receipt fence");
        stale_epoch=epoch; epoch=epoch+1; rstn=0; enable=0; tick(); reset_fenced();
        r=requests.size(); add_owner(128,1,0,b); complete_one(b,r);
        if(owners[a].token!=owners[b].token || owners[a].epoch==owners[b].epoch)
          $fatal(1,"reset recurrence test did not exercise epoch distinction");
        finish("explicit_fenced_reset_new_epoch");
      end
      11,12: begin
        add_owner(128,8,0,a); wait(requests.size()==2); expect_fault=1;
        r=packets.size();
        if(scenario==11) begin
          // A real UR/no-data header has no supported native settlement path.
          // It must quarantine its live tag; emitting End would erase debt.
          @(negedge clk); #1;
          packets.push_back(266'd0); packet_owner.push_back(a); packet_words.push_back(0);
          packets[r][31:0]=32'h0a000000;
          packets[r][63:32]=32'h00002000;
          packets[r][95:64]={16'h0800,requests[0].tag,8'd0};
          packets[r][257:256]=2'b11;
        end else begin
          completion(0,16);
          // Falsely claims the first half is final. The native producer must
          // compare ByteCount and length to this issued tag's remaining span.
          packets[r][43:32]=12'd64;
        end
        wait(consumer_fault); tick();
        if(!producer_fault || producer_fault_reason!=3 || producer_fault_tag!==requests[0].tag ||
           producer_fault_token!==owners[a].token || accepted_total || closed_total || emitted_total)
          $fatal(1,"unsupported/malformed completion erased debt or lost identity");
        finish(scenario==11 ? "no_data_error_retains_debt" : "premature_last_completion");
      end
      13: begin : queued_tag_reuse
        bit reused_payload_tag=0, reused_table_tag=0;
        payload_stall=1;
        add_owner(7,4,0,a); wait(requests.size()==1); completion(0,32);
        wait(payload_write && engine_wait);
        add_owner(128,4,0,b); wait(requests.size()==2); completion(1,32);
        wait(consumed==packets.size());
        // Sixteen new MRds consume the remaining fourteen initial tags plus
        // the two tags whose old destination commands are still outstanding.
        add_owner(192,64,32,c); wait(requests.size()==18);
        for(int q=2;q<18;q++) begin
          reused_payload_tag |= requests[q].tag==requests[0].tag;
          reused_table_tag |= requests[q].tag==requests[1].tag;
        end
        if(!reused_payload_tag || !reused_table_tag || accepted_total || closed_total)
          $fatal(1,"native tag reuse did not overlap stalled older commands");
        payload_stall=0; wait(owners[b].sealed);
        if(owners[c].accepted || owners[c].sealed) $fatal(1,"unreturned owner fabricated progress");
        for(int q=17;q>=2;q--) completion(q,32);
        wait(owners[c].sealed); allow_status=1; emit_ready=1;
        wait(receipts==3 && emitted_total==68 && host_flags==1);
        finish("tag_reuse_with_older_stalled_commands");
      end
      default: $fatal(1,"unknown SCENARIO");
    endcase
  end
endmodule
