// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
`default_nettype none
// DCS is the only source of table requests. Native handshakes retire work.
// No force/release, fabricated owner events, End stimuli, or timeout pass.
module dma_fetch_composition_v1_tb;
  import dma_status_v2_pkg::*;
  logic clk=0, rstn=0, enable=0;
  always #5 clk=~clk;
  logic [31:0] epoch=32'hc001;
  logic [1:0] dcs_cs=0, dcs_write=0, dcs_read=0;
  logic [1:0][7:0] dcs_address=0;
  logic [1:0][31:0] dcs_wdata=0;
  logic [1:0][3:0] dcs_be='1;
  wire [1:0][31:0] dcs_rdata;
  wire [1:0] dcs_wait, dcm_write;
  wire [1:0][63:0] dcm_address;
  wire [1:0][31:0] dcm_data;
  wire [1:0][3:0] dcm_be;
  logic [1:0] dcm_wait=0;
  logic [265:0] rx=0;
  logic [3:0] rx_count=0, tx_count=0;
  wire rx_pop, tag_pop, tx_push;
  wire [259:0] tx;
  logic master_enable=1, grant_enable=1, control_load=0;
  logic [31:0] control_data=0;
  wire control_ready;
  logic allow_admit=1, allow_data_admit=1, allow_status=1, allow_end=1;
  logic allow_read_table=1, allow_write_table=1;
  wire payload_write;
  wire [63:0] payload_address;
  wire [255:0] payload_data;
  wire [31:0] payload_be;
  wire [4:0] payload_burst;
  logic payload_wait=0, write_ready=1, diag_ready=0, local_ready=0;
  wire write_valid, diagnostic_valid, local_valid;
  wire [159:0] write_data;
  wire [31:0] diagnostic_word, local_epoch;
  wire [19:0] local_token;
  wire [7:0] local_reason, local_count;
  wire contract_fault, fetch_fault, controller_fault;
  dma_fetch_composition_v1 dut (.*);

  // Independent software oracle: record programmed addresses and table bytes
  // BEFORE doorbells. Expected descriptors never come from observed DUT data.
  typedef struct {
    logic [159:0] fetch;
    logic [31:0] epoch;
    int destination, first, count, owner, copied, executed;
    bit admitted, sealed, committed, receipt_closed;
  } table_t;
  typedef struct { logic [159:0] data; int table_index, ordinal; } executable_t;
  typedef struct {
    logic [159:0] desc;
    logic [31:0] epoch, success_word;
    logic [19:0] token;
    logic [127:0] seen;
    logic [3:0] cause;
    int table_index, count, issued_dw, returned_dw, accepted, last_accept;
    bit error, sealed, status_seen, host_seen, receipt_closed;
  } owner_t;
  typedef struct {
    int owner, offset_dw, words, supplied;
    logic [7:0] tag;
    logic [63:0] address;
  } request_t;
  table_t tables[$];
  executable_t read_expected[$], write_expected[$];
  owner_t owners[$];
  request_t requests[$];
  int read_fetch_plan[$], write_fetch_plan[$];
  int next_fetch[2]='{0,0}, sw_fetch_serial[2]='{0,0};
  int latest_token[logic [51:0]];
  int data_owner[128];
  logic [31:0] host_memory[longint unsigned];
  logic [31:0] payload_memory[longint unsigned];
  logic [63:0] header_base[2]='{64'h8000,64'ha000};
  logic [63:0] table_destination[2]='{64'h80000100,64'h80002200};
  logic [265:0] packets[$];
  int packet_owner[$], packet_words[$];
  int consumed=0, auto_cursor=0, cycles=0, fetch_admissions=0;
  int read_copy_pos=0, write_copy_pos=0, read_exec_pos=0, write_exec_pos=0;
  int receipts=0, host_flags=0, closures=0, accepted_total=0;
  int scenario=0, receipt_owner=-1, receipt_phase=0, burst_position=0;
  logic [31:0] receipt_word=0;
  bit auto_reply=0, expect_fault=0, order_collision=0, mixed_overlap=0, page_split_seen=0;
  string case_name;

  function automatic logic [159:0] software_descriptor(input int d,input int id,input int revision);
    return {6'b0,8'(id),18'd8,
      64'(32'h400000+$unsigned(revision)*4096+$unsigned(d)*32'h1000000+$unsigned(id)*32),
      64'(32'h200000+$unsigned(revision)*4096+$unsigned(d)*32'h1000000+$unsigned(id)*32)};
  endfunction
  function automatic logic [31:0] memory_word(input logic [63:0] address);
    if(!host_memory.exists(address)) $fatal(1,"host MRd outside software memory %h",address);
    return host_memory[address];
  endfunction
  function automatic int owner_for(input logic [19:0] token,input logic [31:0] ep);
    logic [51:0] key={ep,token};
    return latest_token.exists(key) ? latest_token[key] : -1;
  endfunction
  function automatic int request_for(input int t,input int ordinal);
    int found=-1, n=0;
    foreach(requests[r]) if(requests[r].owner==tables[t].owner) begin
      if(n==ordinal) found=r;
      n++;
    end
    return found;
  endfunction
  task automatic tick;
    @(posedge clk); @(negedge clk); #1;
  endtask
  task automatic csr(input int d,input logic [7:0] address,input logic [31:0] value);
    @(negedge clk); #1;
    dcs_cs[d]=1; dcs_write[d]=1; dcs_address[d]=address; dcs_wdata[d]=value;
    do @(posedge clk); while(dcs_wait[d]);
    @(negedge clk); #1; dcs_cs[d]=0; dcs_write[d]=0;
  endtask
  task automatic configure(input int d,input int last);
    csr(d,8'h00,header_base[d][31:0]); csr(d,8'h04,header_base[d][63:32]);
    csr(d,8'h0c,table_destination[d][63:32]);
    csr(d,8'h08,table_destination[d][31:0]); csr(d,8'h14,$unsigned(last));
  endtask
  task automatic plan_table(input int d,input int first,input int count,input int revision,output int t);
    table_t record;
    executable_t item;
    logic [255:0] entry;
    logic [159:0] desc;
    logic [63:0] address;
    if(first<0 || count<1 || first+count>128) $fatal(1,"invalid software table plan");
    record='{default:'0}; record.owner=-1; record.destination=d;
    record.first=first; record.count=count; record.epoch=epoch;
    record.fetch={6'b0,8'(128+d*64+(sw_fetch_serial[d]%64)),18'(count*8),
      table_destination[d],header_base[d]+64'h200+$unsigned(64'(first*32))};
    sw_fetch_serial[d]++;
    t=tables.size(); tables.push_back(record);
    if(d==0) read_fetch_plan.push_back(t); else write_fetch_plan.push_back(t);
    for(int j=0;j<count;j++) begin
      desc=software_descriptor(d,first+j,revision);
      entry={96'hace051005100aabbccddeeff,desc};
      address=header_base[d]+64'h200+$unsigned(64'((first+j)*32));
      for(int w=0;w<8;w++) host_memory[address+$unsigned(64'(w*4))]=entry[w*32+:32];
      if(d==0) for(int w=0;w<8;w++)
        host_memory[desc[63:0]+$unsigned(64'(w*4))]=32'hcafe0000 ^ $unsigned(revision*4096+(first+j)*8+w);
      item.data=desc; item.table_index=t; item.ordinal=j;
      if(d==0) read_expected.push_back(item); else write_expected.push_back(item);
    end
  endtask
  task automatic doorbell(input int d,input int first,input int count,input int revision,output int t);
    plan_table(d,first,count,revision,t);
    csr(d,8'h10,$unsigned(first+count-1));
  endtask

  // Header uses the native MRd; CplD body uses independent software memory.
  task automatic enqueue_completion(input int r,input int words,input bit replay=0,input int corrupt=0);
    int base, beats, off, pos, o;
    logic [265:0] zero='0;
    if(r<0 || r>=requests.size()) $fatal(1,"unknown native request in completion fixture");
    o=requests[r].owner; off=replay ? 0 : requests[r].supplied;
    if(words<1 || words%8!=0 || off+words>requests[r].words)
      $fatal(1,"invalid finite completion fragment");
    base=packets.size(); beats=(4+words+7)/8;
    repeat(beats) begin packets.push_back(zero); packet_owner.push_back(o); packet_words.push_back(0); end
    packets[base][31:0]=32'h4a000000|$unsigned(words);
    packets[base][63:32]=$unsigned((requests[r].words-off)*4);
    packets[base][95:64]={16'h0800,requests[r].tag,1'b0,7'(requests[r].address+$unsigned(64'(off*4)))};
    packets[base][256]=1;
    for(int w=0;w<words;w++) begin
      pos=w+4;
      packets[base+pos/8][(pos%8)*32+:32]=memory_word(requests[r].address+$unsigned(64'((off+w)*4)));
    end
    packets[base+beats-1][257]=1; packets[base+beats-1][259:258]=2'd2;
    packet_words[base+beats-1]=words;
    if(corrupt==1) packets[base][43:32]=12'($unsigned(words*4)); // premature final fragment
    if(corrupt==2) packets[base][79:72]=8'hfe;        // no such native tag
    if(!replay && corrupt==0) requests[r].supplied+=words;
  endtask
  task automatic completion(input int r,input int words,input bit replay=0,input int corrupt=0);
    @(negedge clk); #1; enqueue_completion(r,words,replay,corrupt);
  endtask
  // Clocked presentation is intentional: queue mutations need not awaken
  // always_comb in VCS. No continuous assignment calls a queue method.
  always @(negedge clk) begin
    if(rstn && auto_reply) begin
      while(auto_cursor<requests.size()) begin
        if(requests[auto_cursor].supplied<requests[auto_cursor].words)
          enqueue_completion(auto_cursor,requests[auto_cursor].words-requests[auto_cursor].supplied);
        auto_cursor++;
      end
    end
    rx=rstn && consumed<packets.size() ? packets[consumed] : 266'b0;
    rx_count=rstn && consumed<packets.size() ? 4'd1 : 4'd0;
  end
  task automatic command(input logic [31:0] value);
    @(negedge clk); #1; control_load=1; control_data=value;
    do @(posedge clk); while(!control_ready);
    @(negedge clk); #1; control_load=0; control_data=0;
  endtask
  task automatic reset_epoch;
    @(negedge clk); #1; rstn=0; enable=0; dcs_cs=0; dcs_write=0;
    tick(); rstn=1; enable=1; tick();
    sw_fetch_serial[0]=0; sw_fetch_serial[1]=0;
    // No warm-up delay stands in for readiness or retirement.
  endtask
  task automatic finish;
    // Let every clocked assertion process the final observed handshake.
    tick();
    $display("PASS dma-fetch-composition-v1 scenario=%0d case=%s fetches=%0d requests=%0d read=%0d write=%0d receipts=%0d host=%0d",
      scenario,case_name,fetch_admissions,requests.size(),read_exec_pos,write_exec_pos,receipts,host_flags);
    $finish;
  endtask

  bit held_engine=0, held_end=0, held_status=0, held_read=0, held_write=0;
  bit [1:0] held_dcm=0;
  logic [480:0] held_engine_bus;
  logic [52:0] held_end_bus;
  logic [31:0] held_status_word;
  logic [159:0] held_read_data, held_write_data;
  logic [1:0][99:0] held_dcm_bus;
  always @(posedge clk) begin : monitor
    int o, t, d, id, ordinal, q, previous;
    logic [63:0] effective, source;
    logic [51:0] key;
    owner_t record;
    request_t request;
    executable_t expected;
    cycles++;
    if(!rstn) begin
      held_engine=0; held_end=0; held_status=0; held_read=0; held_write=0; held_dcm=0;
      receipt_owner=-1; receipt_phase=0; burst_position=0;
    end else begin
      // Return-low closure can coincide with a legal new admission. Account
      // for the old receipt first, before checking finite token/ID reuse.
      if(receipt_owner>=0 && !dut.ack_valid && !dut.ack_consumed && receipt_phase==3) begin
        owners[receipt_owner].receipt_closed=1;
        t=owners[receipt_owner].table_index;
        if(t>=0) tables[t].receipt_closed=1;
        receipts++; receipt_owner=-1; receipt_phase=0;
      end
      if(!expect_fault && (dut.producer_fault || contract_fault || dut.route_fault_now || fetch_fault || controller_fault))
        $fatal(1,"unexpected fault producer=%h route=%h consumer=%h",dut.producer_fault_reason,dut.route_reason_now,dut.fetch_fault_reason);
      if(held_read && (!dut.read_tx_valid || dut.read_tx_data!==held_read_data)) $fatal(1,"read controller changed held TX");
      held_read=dut.read_tx_valid&&!dut.read_tx_ready;
      if(held_read) held_read_data=dut.read_tx_data;
      if(held_write && (!write_valid || write_data!==held_write_data)) $fatal(1,"write controller changed held TX");
      held_write=write_valid&&!write_ready; if(held_write) held_write_data=write_data;
      if(dut.read_tx_valid && dut.read_tx_ready) begin
        record='{default:'0}; record.desc=dut.read_tx_data; record.epoch=epoch;
        record.token=dut.bind_token; record.last_accept=-1; record.table_index=-1;
        record.count=int'(dut.read_tx_data[145:128])/8;
        if(dut.read_tx_data[153]) begin
          d=int'(dut.read_tx_data[152]); q=next_fetch[d];
          if((d==0 && q>=read_fetch_plan.size()) || (d==1 && q>=write_fetch_plan.size()))
            $fatal(1,"controller admitted an unplanned fetch");
          t=d==0 ? read_fetch_plan[q] : write_fetch_plan[q]; next_fetch[d]++;
          if(tables[t].admitted || dut.read_tx_data!==tables[t].fetch ||
             !dut.fetch_issue_valid || dut.fetch_issue_data!==tables[t].fetch ||
             int'(dut.fetch_issue_first)!=tables[t].first || !dut.bind_valid || dut.bind_desc!==tables[t].fetch)
            $fatal(1,"DCS fetch differs from software snapshot t=%0d got=%h expected=%h",t,dut.read_tx_data,tables[t].fetch);
          if(d==1 && (!dut.forward_req || !dut.forward_ack || dut.forward_data!==tables[t].fetch))
            $fatal(1,"write DCS request bypassed or falsely acknowledged");
          record.table_index=t; tables[t].admitted=1; tables[t].owner=owners.size(); fetch_admissions++;
        end else begin
          if(read_exec_pos>=read_expected.size()) $fatal(1,"unexpected executable read descriptor");
          expected=read_expected[read_exec_pos]; t=expected.table_index;
          if(dut.read_tx_data!==expected.data || !tables[t].committed || tables[t].copied<=expected.ordinal)
            $fatal(1,"read controller violates descriptor order/data/commit at %0d",read_exec_pos);
          if(dut.bind_valid || dut.fetch_issue_valid) $fatal(1,"ordinary data misclassified as fetch");
          tables[t].executed++; read_exec_pos++;
          id=int'(dut.read_tx_data[153:146]); previous=data_owner[id];
          if(previous>=0 && !owners[previous].receipt_closed) $fatal(1,"live data ID reused before receipt closure");
          data_owner[id]=owners.size();
        end
        key={epoch,dut.bind_token};
        if(dut.bind_token[19:12]==0 || dut.bind_token[7:0]!==dut.read_tx_data[153:146])
          $fatal(1,"native token disagrees with controller descriptor");
        if(latest_token.exists(key)) begin
          previous=latest_token[key]; t=owners[previous].table_index;
          if(!owners[previous].receipt_closed || (t>=0 && tables[t].copied!=tables[t].count))
            $fatal(1,"finite token recurred before receipt/copier release");
        end
        latest_token[key]=owners.size(); owners.push_back(record);
      end
      if(tx_push) begin
        $display("MRD_TRACE time=%0t source=%h length=%0d remaining=%0d max=%0d select=%b page_dw=%0d pipe=%b load=%b original=%0d sub=%0d",
          $time, dut.producer.cur_src_addr_reg, tx[9:0],
          dut.producer.remain_dwcnt_reg, dut.producer.max_rd,
          dut.producer.rdsize_sel_reg, dut.producer.dw_to_4KB,
          dut.producer.rd_pipe_state, dut.producer.load_cur_desc_size_reg,
          dut.producer.orig_desc_dw_reg, dut.producer.sub_desc_length_reg);
        if($isunknown(tx) || tx[31:24]!=8'h00 || tx[9:0]==0 || tx[9:0]>32 || tx[2:0]!=0)
          $fatal(1,"unexpected native MRd format/length %h",tx);
        // Native metadata attributes an observed MRd; it never defines the
        // expected software descriptor, source span, or completion body.
        o=owner_for(dut.producer.v5_current_meta.token,dut.producer.v5_current_meta.epoch);
        source={32'b0,tx[95:64]};
        if(o<0 || source!==owners[o].desc[63:0]+$unsigned(64'(owners[o].issued_dw*4)) ||
           owners[o].issued_dw+int'(tx[9:0])>owners[o].count*8)
          $fatal(1,"native MRd does not cover admitted software span exactly");
        if(int'(source[11:0])+int'(tx[9:0])*4>4096)
          $fatal(1,"native MRd illegally crosses a 4 KiB boundary");
        if(owners[o].table_index==0 && source[11:0]==0 && source!=owners[o].desc[63:0]) page_split_seen=1;
        request.owner=o; request.offset_dw=owners[o].issued_dw;
        request.words=int'(tx[9:0]); request.supplied=0; request.tag=tx[47:40]; request.address=source;
        requests.push_back(request); owners[o].issued_dw+=request.words;
      end
      if(rx_pop) begin
        if(!rx_count || consumed>=packets.size()) $fatal(1,"native RX underflow");
        if(packet_words[consumed]!=0) owners[packet_owner[consumed]].returned_dw+=packet_words[consumed];
        consumed++;
      end
      if(held_engine && {dut.engine_write,dut.engine_address,dut.engine_data,dut.engine_be,dut.engine_burst,
          dut.return_epoch,dut.return_token,dut.return_base,dut.return_count}!=={1'b1,held_engine_bus})
        $fatal(1,"native return changed data/identity under waitrequest");
      held_engine=dut.engine_write&&dut.engine_wait;
      if(held_engine) held_engine_bus={dut.engine_address,dut.engine_data,dut.engine_be,dut.engine_burst,
        dut.return_epoch,dut.return_token,dut.return_base,dut.return_count};
      if(dut.route_accept !== ((payload_write&&!payload_wait) || (|(dut.dts_write & ~dut.dts_wait))))
        $fatal(1,"return acceptance differs from destination acceptance");
      if(dut.route_accept) begin
        o=owner_for(dut.return_token,dut.return_epoch);
        effective=dut.engine_address+$unsigned(64'(burst_position*32));
        if(o<0 || dut.beat_address!==effective || dut.return_base!==owners[o].desc[127:64] ||
           effective<owners[o].desc[127:64] || (effective-owners[o].desc[127:64])%32!=0)
          $fatal(1,"native return identity/address disagrees with admitted span");
        ordinal=int'((effective-owners[o].desc[127:64])/32);
        if(ordinal>=owners[o].count || owners[o].seen[ordinal] || dut.engine_be!==32'hffffffff)
          $fatal(1,"duplicate/out-of-span/partial native return");
        for(int w=0;w<8;w++) if(dut.engine_data[w*32+:32]!==memory_word(owners[o].desc[63:0]+$unsigned(64'(ordinal*32+w*4))))
          $fatal(1,"return differs from host memory owner=%0d entry=%0d word=%0d",o,ordinal,w);
        t=owners[o].table_index;
        if(t>=0) begin
          d=tables[t].destination;
          if(int'(dut.return_count)!=tables[t].count || !dut.dts_write[d] || dut.dts_wait[d] ||
             dut.dts_token[d]!==owners[o].token || dut.dts_epoch[d]!==owners[o].epoch || int'(dut.dts_index[d])!=ordinal)
            $fatal(1,"returned table changed destination/ordinal/token");
          if(read_exec_pos>0 && owners[o].accepted<owners[o].count) mixed_overlap=1;
        end else begin
          if(!payload_write || payload_data!==dut.engine_data || payload_address!==dut.engine_address ||
             payload_be!==dut.engine_be || payload_burst!==dut.engine_burst)
            $fatal(1,"ordinary payload path bypassed");
          for(int w=0;w<8;w++) payload_memory[effective+$unsigned(64'(w*4))]=payload_data[w*32+:32];
        end
        owners[o].seen[ordinal]=1; owners[o].accepted++; owners[o].last_accept=cycles; accepted_total++;
        burst_position=burst_position+1==int'(dut.engine_burst) ? 0 : burst_position+1;
      end
      if(held_end && (!dut.end_valid || {dut.end_epoch,dut.end_token,dut.end_error}!==held_end_bus))
        $fatal(1,"native End changed while held");
      held_end=dut.end_valid&&!dut.end_ready;
      if(held_end) held_end_bus={dut.end_epoch,dut.end_token,dut.end_error};
      if(dut.end_valid) begin
        o=owner_for(dut.end_token,dut.end_epoch); t=o<0 ? -1 : owners[o].table_index;
        if(o<0 || t<0 || owners[o].sealed || owners[o].returned_dw!=owners[o].issued_dw ||
           owners[o].accepted*8!=owners[o].issued_dw || owners[o].last_accept>=cycles ||
           dut.end_error!==owners[o].error || (!dut.end_error && owners[o].issued_dw!=owners[o].count*8))
          $fatal(1,"native End fabricated closure or lost partial-error identity");
        if(dut.end_ready) begin owners[o].sealed=1; tables[t].sealed=1; closures++; end
      end
      if(held_status && (!dut.engine_status_valid || dut.engine_status_word!==held_status_word))
        $fatal(1,"owner status changed while held");
      held_status=dut.engine_status_valid&&!dut.engine_status_ready;
      if(held_status) held_status_word=dut.engine_status_word;
      if(dut.engine_status_valid && dut.engine_status_ready) begin
        o=owner_for({dut.engine_status_word[23:16],dut.engine_status_word[15:12],dut.engine_status_word[7:0]},epoch);
        if(o<0 || !status_v2_valid(dut.engine_status_word)) $fatal(1,"native status has no exact owner");
        if(status_v2_success(dut.engine_status_word)) begin
          if(owners[o].error || (owners[o].table_index>=0 && !owners[o].sealed)) $fatal(1,"premature native success");
          owners[o].success_word=dut.engine_status_word; owners[o].status_seen=1;
        end else if(dut.engine_status_word[27:24]!==owners[o].cause) $fatal(1,"native error cause changed");
      end
      if(dut.fetch_valid && dut.fetch_ready) begin
        o=owner_for({dut.fetch_word[23:16],dut.fetch_word[15:12],dut.fetch_word[7:0]},epoch);
        t=o<0 ? -1 : owners[o].table_index;
        if(o<0 || t<0 || !status_v2_success(dut.fetch_word) || !tables[t].sealed || owners[o].error ||
           owners[o].accepted!=tables[t].count || tables[t].committed)
          $fatal(1,"premature/duplicate functional table commit");
        tables[t].committed=1;
      end
      if(scenario==1 && tables.size()>=2 && tables[0].committed && tables[1].committed &&
         tables[0].copied<tables[0].count) order_collision=1;
      // Check both physical copier destinations in software admission order,
      // and separately check both actual controller FIFO outputs.
      if(dut.read_controller.v4_emit_valid && dut.read_controller.v4_emit_ready) begin
        d=int'(dut.read_controller.v4_emit_write);
        q=d==0 ? read_copy_pos : write_copy_pos;
        if((d==0 && q>=read_expected.size()) || (d==1 && q>=write_expected.size()))
          $fatal(1,"unknown executable copier beat");
        expected=d==0 ? read_expected[q] : write_expected[q]; t=expected.table_index;
        if(dut.read_controller.v4_emit_data!==expected.data) begin
          if(scenario==1 && order_collision)
            $fatal(1,"EXPECTED_ORDER_VIOLATION expected=%0d actual=%0d",expected.data[153:146],dut.read_controller.v4_emit_data[153:146]);
          $fatal(1,"copier order/data mismatch without collision precondition");
        end
        if(!tables[t].committed || tables[t].copied!=expected.ordinal) $fatal(1,"copier escaped whole-table commit/order");
        tables[t].copied++;
        if(d==0) read_copy_pos++; else write_copy_pos++;
      end
      if(write_valid && write_ready) begin
        if(write_exec_pos>=write_expected.size()) $fatal(1,"unexpected write-controller output");
        expected=write_expected[write_exec_pos]; t=expected.table_index;
        if(write_data!==expected.data || !tables[t].committed || tables[t].copied<=expected.ordinal)
          $fatal(1,"actual write-controller FIFO reordered/lost executable data");
        tables[t].executed++; write_exec_pos++;
      end
      for(int p=0;p<2;p++) begin
        if(held_dcm[p] && {dcm_write[p],dcm_address[p],dcm_data[p],dcm_be[p]}!=={1'b1,held_dcm_bus[p]})
          $fatal(1,"DCM write changed under waitrequest");
        held_dcm[p]=dcm_write[p]&&dcm_wait[p];
        if(held_dcm[p]) held_dcm_bus[p]={dcm_address[p],dcm_data[p],dcm_be[p]};
      end
      if(dcm_write[1]) $fatal(1,"write controller fabricated status without a D2H producer");
      if(dcm_write[0] && !dcm_wait[0]) begin
        if(dcm_address[0]<header_base[0] || dcm_address[0]>=header_base[0]+512 || dcm_address[0][1:0]!=0 ||
           dcm_data[0]!==32'd1 || dcm_be[0]!==4'hf) $fatal(1,"DCM success ABI/address changed");
        id=int'((dcm_address[0]-header_base[0])/4); o=data_owner[id];
        if(o<0 || !owners[o].status_seen || owners[o].host_seen || owners[o].accepted!=owners[o].count)
          $fatal(1,"DCM preceded payload/status or repeated a flag");
        owners[o].host_seen=1; host_flags++;
      end
      if(dut.ack_valid && receipt_owner<0) begin
        o=owner_for({dut.ack_word[23:16],dut.ack_word[15:12],dut.ack_word[7:0]},epoch);
        t=o<0 ? -1 : owners[o].table_index;
        if(o<0 || !status_v2_success(dut.ack_word) || owners[o].receipt_closed ||
           (t>=0 && !tables[t].committed) || (t<0 && !owners[o].host_seen))
          $fatal(1,"receipt preceded exact commit/DCM acceptance");
        receipt_owner=o; receipt_word=dut.ack_word; receipt_phase=1;
      end
      if(receipt_owner>=0) begin
        if(dut.ack_valid && dut.ack_word!==receipt_word) $fatal(1,"receipt identity changed");
        if(dut.ack_valid && dut.ack_consumed) receipt_phase=2;
        if(!dut.ack_valid && dut.ack_consumed && receipt_phase==2) receipt_phase=3;
      end
    end
  end
  initial begin : stimulus
    int a,b,c,r0,r1,p0,p1,p2,p3,old_owner,first_owner;
    logic [19:0] original_token;
    logic [31:0] original_epoch, collision_word;
    if(!$value$plusargs("SCENARIO=%d",scenario)) scenario=0;
    for(int i=0;i<128;i++) data_owner[i]=-1;
    reset_epoch();
    case(scenario)
      0: begin
        case_name="mixed"; allow_status=0; allow_end=0; dcm_wait[0]=1; write_ready=0;
        configure(0,7); configure(1,7);
        doorbell(0,0,4,0,a); doorbell(1,0,8,0,b);
        wait(tables[a].admitted && tables[b].admitted);
        wait(owners[tables[a].owner].issued_dw==32 && owners[tables[b].owner].issued_dw==64);
        r0=request_for(a,0); completion(r0,32);
        wait(dut.end_valid);
        if(dut.end_token!==owners[tables[a].owner].token || owners[tables[b].owner].accepted!=0)
          $fatal(1,"per-owner closure precondition missing");
        repeat(5) begin tick(); if(tables[a].sealed || read_exec_pos!=0 || receipts!=0) $fatal(1,"held End bypassed"); end
        allow_end=1; wait(tables[a].sealed && dut.engine_status_valid);
        repeat(5) begin tick(); if(read_copy_pos!=0 || receipts!=0 || !dut.engine_status_valid) $fatal(1,"data-before-status hold failed"); end
        allow_status=1; wait(read_exec_pos==4);
        wait(requests.size()==7);
        r0=request_for(b,0); r1=request_for(b,1);
        p0=3; p1=4; p2=5; p3=6;
        if(requests[p0].owner==tables[b].owner || requests[p3].owner==tables[a].owner)
          $fatal(1,"payload/table overlap requests absent");
        @(negedge clk); #1; payload_wait=1;
        completion(r0,16); completion(p0,8); completion(r1,16);
        completion(p1,8); completion(r0,16); completion(p2,8); completion(r1,16);
        wait(payload_write && payload_wait);
        repeat(5) begin tick(); if(host_flags!=0 || tables[b].sealed) $fatal(1,"held payload fabricated progress"); end
        payload_wait=0;
        // Observe the last beat before its acceptance edge, then hold it.
        do begin @(negedge clk); #1; end
        while(!(dut.dts_write[1] && dut.dts_index[1]==7));
        if(owners[tables[b].owner].accepted!=7) $fatal(1,"last-beat stall precondition absent");
        allow_write_table=0;
        repeat(5) begin tick(); if(owners[tables[b].owner].accepted!=7 || tables[b].sealed)
          $fatal(1,"last table beat stall did not retain native debt"); end
        allow_write_table=1; completion(p3,8);
        wait(tables[b].sealed && write_valid && dcm_write[0]);
        if(write_exec_pos!=0 || host_flags!=0 || !mixed_overlap) $fatal(1,"mixed/stalled endpoint preconditions absent");
        repeat(5) tick(); write_ready=1; dcm_wait[0]=0;
        wait(write_exec_pos==8 && host_flags==4 && receipts==6);
        if(read_exec_pos!=4 || read_copy_pos!=4 || write_copy_pos!=8 || closures!=2)
          $fatal(1,"mixed composition totals differ");
        finish();
      end
      1: begin
        case_name="queued_wrap_order"; allow_admit=0; allow_data_admit=0; allow_status=0;
        // Full tables cross a 4 KiB MRd boundary. The next ring doorbell is
        // queued while the first immutable controller TX is held.
        header_base[0]=64'h8da0; configure(0,127);
        doorbell(0,0,128,0,a); wait(dut.read_tx_valid && dut.read_tx_data[153]);
        doorbell(0,0,128,0,b);
        if(fetch_admissions!=0 || dut.read_tx_data!==tables[a].fetch) $fatal(1,"doorbell replaced held fetch");
        auto_reply=1; allow_admit=1;
        wait(tables[a].sealed && tables[b].sealed);
        @(negedge clk); #1;
        if(read_copy_pos!=0 || read_exec_pos!=0 || receipts!=0) $fatal(1,"table executed before status release");
        allow_status=1; wait(tables[a].committed && tables[b].committed);
        if(tables[a].copied==tables[a].count) $fatal(1,"two-committed-table collision absent");
        wait(tables[a].copied==128); @(negedge clk); #1; allow_data_admit=1;
        wait(read_exec_pos==256 && host_flags==256 && receipts==258);
        if(!order_collision || !page_split_seen) $fatal(1,"order or native page-split precondition never occurred");
        doorbell(0,0,4,1,c);
        wait(tables[c].receipt_closed && tables[c].executed==4 && host_flags==260 && receipts==263);
        if(tables[c].fetch[63:0]!==header_base[0]+512) $fatal(1,"wrap oracle error");
        finish();
      end
      2: begin
        case_name="fifo_table_credit"; write_ready=0; auto_reply=1; configure(1,127);
        // Existing capacities, not a traffic cap: 252 accepted output entries
        // (251 FIFO + held TX), then 16 live table banks, then a blocked query.
        for(int n=0;n<32;n++) begin
          doorbell(1,(n%8)*16,16,0,a);
          if(n<31) wait(tables[a].receipt_closed);
        end
        wait(dut.write_controller.dt_fifo_count==251 && dut.copy_valid && !dut.copy_ready &&
             dut.read_controller.fetch_consumer.live==16'hffff && dut.forward_req &&
             !dut.read_controller.v4_issue_ready);
        if(fetch_admissions!=31 || tables[a].admitted || write_exec_pos!=0 || write_copy_pos!=252)
          $fatal(1,"FIFO AND table-bank credit collision absent");
        repeat(5) begin tick(); if(tables[a].admitted || dut.forward_ack || write_exec_pos!=0)
          $fatal(1,"credit-blocked fetch/destination accepted"); end
        write_ready=1;
        wait(tables[a].receipt_closed && write_exec_pos==512 && receipts==32);
        if(write_copy_pos!=512 || fetch_admissions!=32 || host_flags!=0 || read_exec_pos!=0)
          $fatal(1,"credit release lost or misrouted work");
        finish();
      end
      3,4: begin
        case_name=scenario==3 ? "master_partial_drain" : "abort_partial_drain";
        configure(0,7); doorbell(0,0,8,0,a);
        wait(requests.size()==1); @(negedge clk); #1; grant_enable=0;
        owners[tables[a].owner].error=1;
        owners[tables[a].owner].cause=scenario==3 ? DMA_CAUSE_MASTER : DMA_CAUSE_ABORT;
        if(scenario==3) master_enable=0; else command(32'd4);
        wait(diagnostic_valid);
        if(tables[a].sealed || accepted_total!=0 || diagnostic_word[27:24]!==owners[tables[a].owner].cause ||
           {diagnostic_word[23:16],diagnostic_word[15:12],diagnostic_word[7:0]}!==owners[tables[a].owner].token)
          $fatal(1,"partial-drain diagnostic cause/identity lost");
        repeat(5) begin tick(); if(closures!=0 || dut.ack_valid || read_exec_pos!=0 || host_flags!=0) $fatal(1,"error erased native debt"); end
        completion(0,32); wait(tables[a].sealed && local_valid);
        if(local_token!==owners[tables[a].owner].token || local_epoch!==epoch || local_reason!=1 || local_count!=4 ||
           requests.size()!=1 || read_copy_pos!=0 || dut.ack_valid || tables[a].committed)
          $fatal(1,"partial native drain fabricated executable success");
        @(negedge clk); #1; diag_ready=1; local_ready=1; repeat(5) tick();
        if(read_exec_pos!=0 || receipts!=0 || host_flags!=0 || !dut.read_controller.fetch_consumer.live)
          $fatal(1,"failed table lost retained custody");
        finish();
      end
      5,6: begin
        case_name=scenario==5 ? "malformed" : "unattributable";
        configure(0,7); doorbell(0,0,8,0,a); wait(requests.size()==2); expect_fault=1;
        completion(0,16,0,scenario==5 ? 1 : 2);
        wait(fetch_fault); tick();
        original_token=scenario==5 ? owners[tables[a].owner].token : 20'b0;
        if(!dut.producer_fault || dut.producer_fault_reason!=3 || dut.producer_fault_token!==original_token ||
           dut.producer_fault_epoch!==epoch || dut.producer_fault_tag!==(scenario==5 ? requests[0].tag : 8'hfe) ||
           dut.fetch_fault_reason!=8'h83 || dut.fetch_fault_token!==original_token || dut.fetch_fault_epoch!==epoch ||
           dut.fetch_fault_index!==(scenario==5 ? requests[0].tag : 8'hfe) ||
           accepted_total!=0 || closures!=0 || receipts!=0 || read_copy_pos!=0 || read_exec_pos!=0 || host_flags!=0)
          $fatal(1,"malformed/unattributable return lost first-fault identity or cancelled raw debt");
        finish();
      end
      7: begin
        case_name="status_collision"; allow_status=0; configure(0,0);
        doorbell(0,0,1,0,a); wait(requests.size()==1); completion(0,8);
        wait(tables[a].sealed && dut.engine_status_valid);
        if(!status_v2_success(dut.engine_status_word)) $fatal(1,"collision lacks held native success");
        collision_word=dut.engine_status_word;
        expect_fault=1; completion(0,8,1);
        // Release only after the clocked FIFO exposes the replay header,
        // colliding its fault with native status -> actual controller sink.
        @(negedge clk); #1;
        if(!rx_count || !rx[256] || !dut.producer_fault || !dut.engine_status_valid || !dut.controller_status_ready)
          $fatal(1,"header-fault/staged-success collision was not presented");
        allow_status=1; wait(fetch_fault); tick();
        // Follow the accepted native success into the actual sink. A fault
        // must leave that staged success uncommitted, not merely delay it.
        wait(dut.fetch_valid && !dut.fetch_ready);
        repeat(3) begin
          tick();
          if(!dut.fetch_valid || dut.fetch_ready || dut.fetch_word!==collision_word || dut.ack_valid)
            $fatal(1,"faulted controller sink released or changed staged success");
        end
        if(tables[a].committed || read_copy_pos!=0 || read_exec_pos!=0 || receipts!=0 || dut.ack_valid || host_flags!=0 ||
           dut.producer_fault_reason!=3 || dut.producer_fault_token!=0 || dut.producer_fault_tag!==requests[0].tag)
          $fatal(1,"unowned replay plus held success escaped quarantine");
        finish();
      end
      8: begin
        case_name="finite_owner_reuse16321"; auto_reply=1; configure(1,0);
        // Real controllers rotate SIX ID bits. Same slot + full ID + eight-bit
        // generation recurs after lcm(64,255)=16320 lifecycles, not after 255.
        for(int lifecycle=0;lifecycle<=64*255;lifecycle++) begin
          doorbell(1,0,1,lifecycle,a);
          wait(tables[a].receipt_closed && tables[a].executed==1);
          old_owner=tables[a].owner;
          if(lifecycle==0) begin original_token=owners[old_owner].token; first_owner=old_owner; end
          if(owners[old_owner].token[11:8]!=0 || owners[old_owner].token[19:12]!=8'($unsigned((lifecycle%255)+1)) ||
             owners[old_owner].token[7:0]!=8'($unsigned(192+(lifecycle%64))))
            $fatal(1,"native finite allocation/controller ID recurrence changed");
          if(lifecycle==64*255 && (owners[old_owner].token!==original_token || !owners[first_owner].receipt_closed))
            $fatal(1,"full finite-token recurrence was not exercised safely");
        end
        if(write_exec_pos!=64*255+1 || receipts!=64*255+1) $fatal(1,"recurrence oracle totals wrong");
        finish();
      end
      9: begin
        case_name="fenced_reset_epoch"; auto_reply=1; configure(1,0);
        doorbell(1,0,1,0,a); wait(tables[a].receipt_closed && tables[a].executed==1); tick();
        if(consumed!=packets.size() || dut.route_busy || dut.ack_valid || dut.ack_consumed ||
           dut.producer.v2_owners.live_q!=0) $fatal(1,"reset lacks actual transport/owner/receipt fence");
        original_token=owners[tables[a].owner].token; original_epoch=epoch;
        // The fixture discards no outstanding packet. Hardware must provide
        // its own reset/transport fence; epoch change alone is not a fence.
        @(negedge clk); #1; rstn=0; enable=0; epoch=epoch+1;
        reset_epoch(); configure(1,0); doorbell(1,0,1,1,b);
        wait(tables[b].receipt_closed && tables[b].executed==1);
        if(owners[tables[b].owner].token!==original_token || owners[tables[b].owner].epoch==original_epoch || receipts!=2)
          $fatal(1,"reset failed to exercise token recurrence in a new epoch");
        finish();
      end
      default: $fatal(1,"unknown SCENARIO");
    endcase
  end
endmodule
`default_nettype wire
