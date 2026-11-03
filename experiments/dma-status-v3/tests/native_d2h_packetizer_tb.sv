`timescale 1ns/1ps
// Owned full-wrapper fixture. Compile actual private readmem/aligner/TLPgen
// and real FIFO, lpm_add_sub and altsyncram dependencies. No IP stubs or force.
// Output FIFO dequeue is a simulated consumer, not PCIe or host delivery.
module native_d2h_packetizer_tb;
  logic pcie_clk=0,user_clk=0,common_cold_reset_n=0;
  always #5 pcie_clk=~pcie_clk;
  always #7 user_clk=~user_clk;
  logic app_nreset_status=1,backend_reset_n=1,memory_ready=1,memory_failed=0,quiesce=1;
  logic [63:0] rd_dma_address_o=0;
  wire [63:0] wr_dma_address_o;
  logic rd_dma_write_o=0;
  wire wr_dma_read_o;
  logic [255:0] rd_dma_write_data_o=0;
  logic [31:0] rd_dma_byte_enable_o=0;
  wire [31:0] wr_dma_read_byte_enable_o;
  logic [4:0] rd_dma_burst_count_o=1;
  wire [4:0] wr_dma_burst_count_o;
  wire rd_dma_wait_request_i,wr_dma_wait_request_i,wr_dma_read_data_valid_i;
  wire [255:0] wr_dma_read_data_i;
  wire busy,quiesced,fault,ddr_lock,mux_fault;
  wire [3:0] fault_code;
  wire [63:0] fault_address;
  wire [4:0] owned_beats;
  logic [24:0] core_address=25'h123456;
  logic core_read=0,core_write=0;
  logic [511:0] core_writedata=0;
  logic [63:0] core_byteenable='1;
  wire core_waitrequest,core_readdatavalid,core_readdataerror;
  wire [511:0] core_readdata;
  wire [24:0] avm_address;
  wire avm_read,avm_write;
  wire [511:0] avm_writedata;
  wire [63:0] avm_byteenable;
  wire [0:0] avm_burstcount;
  logic avm_waitrequest=1;
  wire avm_readdatavalid;
  logic avm_readdataerror=0;
  wire [511:0] avm_readdata;
  dma_memory_path_unaligned_candidate path(.*);

  logic [159:0] rx_data=0;
  logic rx_valid=0;
  wire rx_ready,status_valid;
  wire [31:0] status_data;
  logic [259:0] side_data=0;
  logic [3:0] side_count=0;
  wire side_pop,arb_req,tx_write;
  logic grant=0,hp_pending=0;
  logic [4:0] tx_count=0;
  wire [259:0] tx_data;
  logic [12:0] busdev=13'h123;
  logic [31:0] devcsr=0;
  altpcieav_dma_wr_2 dma (
    .Clk_i(pcie_clk),.Srst_i(!common_cold_reset_n),
    .WrDmaRead_o(wr_dma_read_o),.WrDmaAddress_o(wr_dma_address_o),
    .WrDmaBurstCount_o(wr_dma_burst_count_o),.WrDmaReadByteEnable_o(wr_dma_read_byte_enable_o),
    .WrDmaWaitRequest_i(wr_dma_wait_request_i),
    .WrDmaReadDataValid_i(wr_dma_read_data_valid_i),.WrDmaReadData_i(wr_dma_read_data_i),
    .WrDmaRxData_i(rx_data),.WrDmaRxValid_i(rx_valid),.WrDmaRxReady_o(rx_ready),
    .WrDmaTxData_o(status_data),.WrDmaTxValid_o(status_valid),
    .SideFifoData_i(side_data),.SideFifoCount_i(side_count),.SideFifoRdreq_o(side_pop),
    .HPRxmPending_i(hp_pending),.WrDmaArbReq_o(arb_req),.WrDmaGrant_i(grant),
    .TxFifoCount_i(tx_count),.TxFifoData_o(tx_data),.TxFifoWrReq_o(tx_write),
    .BusDev_i(busdev),.DevCsr_i(devcsr));

  // Explicit target-family simulation configuration: the retained source
  // selects Stratix V, unsupported by the 26.1 model. Source bytes stay intact.
  defparam dma.dma_wr_wdalign.tlp_header_fifo.intended_device_family = "Arria 10";

  typedef struct {
    logic [63:0] src,dst;
    int unsigned words,mps,issued_dw;
    logic [7:0] id;
    longint unsigned enqueued,drained;
    bit status_seen;
  } desc_t;
  typedef struct packed {logic [63:0] base; logic [31:0] mask;} beat_t;
  desc_t descriptors[$];
  beat_t backend_expected[$],return_expected[$];
  int native_index=0,metadata_index=0,status_index=0;
  // Two independent decoders: monitor 0 sees enqueue, monitor 1 sees dequeue.
  int packet_desc[2]='{0,0};
  bit in_packet[2]='{0,0};
  int packet_words[2],packet_start[2],packet_beats[2],packet_beat[2],packet_seen[2];
  logic [63:0] packet_address[2];
  int packet_count[2]='{0,0},side_packets[2]='{0,0};
  logic [259:0] tx_fifo[$],side_fifo[$],side_expected_enqueue[$],side_expected_drain[$];
  bit sink_pop=0,sink_hold=1,submissions_done=0,core_enable=0,side_enable=0;
  int side_sequence=0,side_reads=0,side_generated=0,tx_highwater=0;
  int native_commands=0,backend_commands=0,returns=0,complete_pops=0;
  int core_commands=0,core_returns=0,core_overlaps=0;
  int native_stalls=0,backend_stalls=0,grant_stalls=0,tx_pressure_cycles=0,hp_cycles=0;
  int immediate_returns=0,delayed_returns=0,status_while_queued=0;
  longint unsigned raw_written=0,raw_released=0,aligned_written=0,aligned_read=0,aligned_credited=0;
  logic [9:0] prev_raw_limit=0,prev_aligned_limit=0;
  int raw_wraps=0,aligned_wraps=0;
  int response_delay=19,grant_delay=7,grant_left=0;
  int unsigned seed=1,backend_rng=1,tx_rng=1;
  string selected_case="matrix";
  bit quarantine=0,quarantine_started=0;
  function automatic int unsigned next_random(input int unsigned s);
    s=s^(s<<13);s=s^(s>>17);s=s^(s<<5);return s;
  endfunction
  function automatic logic [7:0] byte_at(input logic [63:0] address);
    logic [31:0] mixed;
    // Odd multiplication and xor-shift are permutations of 32-bit DWORD
    // indices. Complete DWORDs have distinct data throughout the 2GiB source
    // aperture; a duplicated 256B block cannot hide behind a periodic pattern.
    mixed=32'((address>>2)^(address>>34))*32'h9e3779b1;
    mixed=mixed^(mixed>>16);
    return 8'(mixed>>(8*address[1:0]));
  endfunction
  function automatic logic [31:0] span_mask(input int first,input int bytes);
    logic [31:0] r;
    r='0;
    for(int k=0;k<32;k++) if(k>=first && k<first+bytes) r[k]=1;
    return r;
  endfunction
  function automatic int minimum(input int a,input int b);
    return a<b?a:b;
  endfunction
  function automatic logic [259:0] make_side(input int sequence_number);
    logic [259:0] v;
    v='0;v[31:0]=32'h40000001;
    v[63:32]={{busdev,3'b000},8'ha5,4'h0,4'hf};
    v[95:64]=32'h90000004+32'(8*sequence_number);
    v[127:96]=32'hcafe0000^32'(sequence_number);
    v[256]=1;v[257]=1;v[259:258]=2;
    return v;
  endfunction

  // Decode the real 260-bit interface. The header length identifies payload
  // DWORDs; EMPTY counts unused 64-bit QWORDs. Never count alignment holes.
  task automatic accept_packet_word(input logic [259:0] v,input int monitor);
    logic [31:0] h0,h1,h2,h3;
    logic [63:0] address,wanted_address,actual_byte_address,source_address;
    logic [259:0] expected_side;
    logic [7:0] got;
    int fmt,length,expected_length,start,valid_dw,remaining,expected_empty,di;
    longint unsigned cursor;
    if($isunknown(v[259:256])) $fatal(1,"D2H_FRAMING_X monitor=%0d",monitor);
    if(v[256] && v[47:40]==8'ha5) begin
      if(in_packet[monitor]) $fatal(1,"D2H_SIDE_INTERLEAVED");
      if(monitor==0) begin
        if(side_expected_enqueue.size()==0) $fatal(1,"D2H_EXTRA_SIDE");
        expected_side=side_expected_enqueue.pop_front();
      end else begin
        if(side_expected_drain.size()==0) $fatal(1,"D2H_EXTRA_SIDE_DRAIN");
        expected_side=side_expected_drain.pop_front();
      end
      if(v!==expected_side) $fatal(1,"D2H_SIDE_CORRUPTION");
      side_packets[monitor]++;
      return;
    end
    di=packet_desc[monitor];
    if(di>=descriptors.size()) $fatal(1,"D2H_UNOWNED_PACKET monitor=%0d",monitor);
    cursor=(monitor==0)?descriptors[di].enqueued:descriptors[di].drained;
    if(v[256]) begin
      if(in_packet[monitor]) $fatal(1,"D2H_NESTED_SOP");
      if($isunknown(v[95:0])) $fatal(1,"D2H_HEADER_X");
      h0=v[31:0];h1=v[63:32];h2=v[95:64];h3=v[127:96];
      fmt=int'(h0[31:24]);length=int'(h0[9:0]);
      if(fmt!=8'h40 && fmt!=8'h60) $fatal(1,"D2H_HEADER_FORMAT %h",h0);
      if(length==0 || length>int'(descriptors[di].mps)) $fatal(1,"D2H_MPS_LENGTH");
      if(h0!==(32'(fmt)<<24 | 32'(length))) $fatal(1,"D2H_HEADER_DW0");
      if(h1!=={{busdev,3'b000},8'h00,(length==1?4'h0:4'hf),4'hf})
        $fatal(1,"D2H_BYTE_ENABLE_OR_REQUESTER %h",h1);
      if(fmt==8'h60 && $isunknown(h3)) $fatal(1,"D2H_ADDRESS_X");
      address=(fmt==8'h60)?{h2,h3}:{32'b0,h2};
      wanted_address=descriptors[di].dst+cursor;
      if(address!==wanted_address || address[1:0]!=0 || ((address[63:32]!=0)!=(fmt==8'h60)))
        $fatal(1,"D2H_ADDRESS descriptor=%0d got=%h expected=%h",di,address,wanted_address);
      remaining=int'(descriptors[di].words)-int'(cursor/4);
      expected_length=minimum(remaining,int'(descriptors[di].mps));
      expected_length=minimum(expected_length,(4096-int'(address[11:0]))/4);
      if(address[4:0]!=0) expected_length=minimum(expected_length,(32-int'(address[4:0]))/4);
      if(length!=expected_length || int'(address[11:0])+4*length>4096)
        $fatal(1,"D2H_SPLIT descriptor=%0d length=%0d expected=%0d",di,length,expected_length);
      start=(fmt==8'h60)?(address[2]?5:4):(address[2]?3:4);
      packet_address[monitor]=address;packet_words[monitor]=length;packet_start[monitor]=start;
      packet_beats[monitor]=(start+length+7)/8;packet_beat[monitor]=0;packet_seen[monitor]=0;
      in_packet[monitor]=1;
    end else if(!in_packet[monitor]) $fatal(1,"D2H_MISSING_SOP");
    start=(packet_beat[monitor]==0)?packet_start[monitor]:0;
    valid_dw=minimum(8-start,packet_words[monitor]-packet_seen[monitor]);
    for(int lane=0;lane<valid_dw;lane++) for(int b=0;b<4;b++) begin
      actual_byte_address=packet_address[monitor]+64'(4*(packet_seen[monitor]+lane)+b);
      wanted_address=descriptors[di].dst+cursor;source_address=descriptors[di].src+cursor;
      got=v[32*(start+lane)+8*b+:8];
      if(actual_byte_address!==wanted_address || got!==byte_at(source_address))
        $fatal(1,"D2H_BYTE descriptor=%0d monitor=%0d destination=%h expected_dst=%h source=%h got=%h want=%h",
          di,monitor,actual_byte_address,wanted_address,source_address,got,byte_at(source_address));
      // This streaming byte scoreboard rejects duplicates, gaps and reordering
      // without allocating a bounded or aliasing host-memory array.
      cursor++;
    end
    packet_seen[monitor]+=valid_dw;packet_beat[monitor]++;
    if(v[257] !== (packet_beat[monitor]==packet_beats[monitor])) $fatal(1,"D2H_EOP_POSITION");
    if(v[257]) begin
      expected_empty=((8-((packet_start[monitor]+packet_words[monitor])%8))%8)/2;
      if(v[259:258]!==2'(expected_empty) || packet_seen[monitor]!=packet_words[monitor])
        $fatal(1,"D2H_EMPTY_OR_PAYLOAD_COUNT");
      in_packet[monitor]=0;packet_count[monitor]++;
    end else if(v[259:258]!==2'b00) $fatal(1,"D2H_NONFINAL_EMPTY");
    if(monitor==0) descriptors[di].enqueued=cursor;
    else descriptors[di].drained=cursor;
    if(cursor>4*longint'(descriptors[di].words)) $fatal(1,"D2H_EXTRA_BYTES");
    if(cursor==4*longint'(descriptors[di].words)) begin
      if(!v[257]) $fatal(1,"D2H_DESCRIPTOR_END_WITHOUT_EOP");
      packet_desc[monitor]++;
    end
  endtask

  // One monitor owns ingress, TX enqueue and status. Check enqueue first so
  // status may legally coincide with acceptance of the final registered beat.
  always @(posedge pcie_clk) begin : observe
    desc_t d;
    beat_t beat;
    logic [159:0] metadata;
    logic [259:0] word;
    logic [63:0] address;
    logic [64:0] endpoint;
    logic [31:0] mask;
    int remaining,offset,take_dw,beats,delta;
    if(common_cold_reset_n) begin
      if(mux_fault || (fault && !quarantine)) $fatal(1,"D2H_PATH_FAULT code=%0d address=%h",fault_code,fault_address);
      if(rx_valid && rx_ready) begin
        d.src=rx_data[63:0];d.dst=rx_data[127:64];d.words=int'(rx_data[145:128]);
        d.id=rx_data[153:146];d.mps=(devcsr[7:5]==0)?32:64;
        d.issued_dw=0;d.enqueued=0;d.drained=0;d.status_seen=0;
        descriptors.push_back(d);
      end
      if(wr_dma_read_o) begin
        if(native_index>=descriptors.size()) $fatal(1,"D2H_UNOWNED_COMMAND");
        address=descriptors[native_index].src+64'(4*descriptors[native_index].issued_dw);
        remaining=int'(descriptors[native_index].words-descriptors[native_index].issued_dw);
        offset=int'(address[4:0]);
        if(remaining<=0) $fatal(1,"D2H_EXTRA_COMMAND");
        if(offset!=0) begin
          take_dw=minimum(remaining,(32-offset)/4);beats=1;mask=span_mask(offset,4*take_dw);
        end else if(remaining>=128) begin take_dw=128;beats=16;mask='1;end
        else if(remaining<8) begin take_dw=remaining;beats=1;mask=span_mask(0,4*take_dw);end
        else begin beats=remaining/8;take_dw=8*beats;mask='1;end
        if(wr_dma_address_o!==address || wr_dma_burst_count_o!==5'(beats) || wr_dma_read_byte_enable_o!==mask)
          $fatal(1,"D2H_NATIVE_COMMAND descriptor=%0d address=%h expected=%h burst=%0d expected_burst=%0d mask=%h expected_mask=%h",native_index,wr_dma_address_o,address,wr_dma_burst_count_o,beats,wr_dma_read_byte_enable_o,mask);
        if(wr_dma_wait_request_i) native_stalls++;
        else begin
          endpoint={1'b0,address[63:5],5'b0}+65'(beats*32);
          if(endpoint>65'h080000000) $fatal(1,"D2H_APERTURE_ACCEPTANCE");
          for(int j=0;j<beats;j++) begin
            beat.base={address[63:5],5'b0}+64'(32*j);beat.mask=mask;
            backend_expected.push_back(beat);return_expected.push_back(beat);
          end
          descriptors[native_index].issued_dw+=take_dw;native_commands++;
          if(descriptors[native_index].issued_dw==descriptors[native_index].words) native_index++;
        end
      end
      if(wr_dma_read_data_valid_i) begin
        if(return_expected.size()==0) $fatal(1,"D2H_UNOWNED_RETURN");
        beat=return_expected.pop_front();
        for(int b=0;b<32;b++) if(beat.mask[b] && wr_dma_read_data_i[8*b+:8]!==byte_at(beat.base+64'(b)))
          $fatal(1,"D2H_NATIVE_RETURN_BYTE");
        returns++;
      end
      if(dma.desc_fifo_rdreq) begin
        if(metadata_index>=descriptors.size() || dma.desc_fifo_count==0) $fatal(1,"D2H_DESCRIPTOR_POP");
        d=descriptors[metadata_index];beats=(int'(d.src[4:0])+4*int'(d.words)+31)/32;
        metadata={1'b0,5'b0,d.id,18'(d.words),d.dst,16'b0,16'(beats),d.src[31:0]};
        if(dma.desc_fifo_data!==metadata) $fatal(1,"D2H_DESCRIPTOR_METADATA descriptor=%0d",metadata_index);
        metadata_index++;
      end
      if(dma.desc_data_complete_fifo_rdreq) begin
        if(dma.desc_data_complete_fifo_count==0 || complete_pops>=metadata_index)
          $fatal(1,"D2H_COMPLETION_FIFO_UNDERFLOW");
        complete_pops++;
      end
      delta=int'(10'(dma.raw_buffer_limit-prev_raw_limit));
      if(delta>1) $fatal(1,"D2H_RAW_LIMIT_JUMP");
      if(dma.raw_buffer_limit<prev_raw_limit) raw_wraps++;
      raw_written+=delta;prev_raw_limit=dma.raw_buffer_limit;
      if(dma.raw_buff_release) raw_released+=dma.raw_buff_release_size;
      if(raw_released>raw_written || raw_written-raw_released>512) $fatal(1,"D2H_RAW_CREDIT");
      delta=int'(10'(dma.aligned_buffer_limit-prev_aligned_limit));
      if(delta>1) $fatal(1,"D2H_ALIGNED_LIMIT_JUMP");
      if(dma.aligned_buffer_limit<prev_aligned_limit) aligned_wraps++;
      aligned_written+=delta;prev_aligned_limit=dma.aligned_buffer_limit;
      if(dma.dma_wr_tlpgen.buffer_read_enable) aligned_read++;
      if(dma.tlp_gen_cred_up) aligned_credited+=dma.tlp_gen_cred;
      if(aligned_read>aligned_written || aligned_credited>aligned_read || aligned_written-aligned_credited>512)
        $fatal(1,"D2H_ALIGNED_CREDIT");
      if(arb_req && !grant) grant_stalls++;
      if(hp_pending && arb_req) hp_cycles++;
      if(tx_count>=16) tx_pressure_cycles++;
      if(dma.dma_wr_tlpgen.tlpgen_send_state && !grant) $fatal(1,"D2H_SEND_WITHOUT_GRANTED_OWNERSHIP");
      if(sink_pop && tx_fifo.size()!=0) begin word=tx_fifo.pop_front();accept_packet_word(word,1);end
      if(tx_write) begin
        if(tx_fifo.size()>=32) $fatal(1,"D2H_TX_FIFO_OVERFLOW");
        accept_packet_word(tx_data,0);tx_fifo.push_back(tx_data);
      end
      if(tx_fifo.size()>tx_highwater) tx_highwater=tx_fifo.size();
      if(status_valid) begin
        if(status_index>=descriptors.size()) $fatal(1,"D2H_EXTRA_STATUS");
        if(packet_desc[0]<=status_index || descriptors[status_index].enqueued!=4*longint'(descriptors[status_index].words))
          $fatal(1,"D2H_STATUS_EARLY descriptor=%0d enqueued=%0d required=%0d tx_write=%b",
            status_index,descriptors[status_index].enqueued,4*descriptors[status_index].words,tx_write);
        if(status_data!=={23'b0,1'b1,descriptors[status_index].id} || descriptors[status_index].status_seen)
          $fatal(1,"D2H_STATUS_ID_OR_DUPLICATE");
        if(!tx_write || !tx_data[257] || (tx_data[256] && tx_data[47:40]==8'ha5))
          $fatal(1,"D2H_STATUS_WITHOUT_FINAL_ENQUEUE");
        if(tx_fifo.size()!=0) status_while_queued++;
        descriptors[status_index].status_seen=1;status_index++;
      end
      if(side_pop) begin
        if(side_fifo.size()==0) $fatal(1,"D2H_SIDE_UNDERFLOW");
        word=side_fifo.pop_front();side_reads++;
      end
    end
  end

  // Finite 32-entry FIFO; actual occupancy drives the almost-full contract.
  // No per-beat ready exists on this interface. Grant persists through SEND
  // and its registered output tail. Side FIFO is an active show-ahead source.
  always @(negedge pcie_clk) begin : tx_environment
    logic [259:0] word;
    if(!common_cold_reset_n) begin
      grant=0;grant_left=grant_delay;sink_pop=0;tx_count=0;side_count=0;side_data=0;hp_pending=0;
    end else begin
      tx_rng=next_random(tx_rng);
      if(!arb_req && !tx_write) begin grant=0;grant_left=int'(tx_rng%32'(grant_delay+1));end
      else if(arb_req && !grant) begin
        if(grant_left==0) grant=1;
        else grant_left--;
      end
      hp_pending=tx_rng[7:5]==3'b010;
      if(side_enable && side_fifo.size()<3 && tx_rng[11:8]==0) begin
        word=make_side(side_sequence);side_sequence++;side_generated++;
        side_fifo.push_back(word);side_expected_enqueue.push_back(word);side_expected_drain.push_back(word);
      end
      side_count=4'(side_fifo.size());side_data=side_fifo.size()?side_fifo[0]:'x;
      tx_count=tx_fifo.size()==32?5'd31:5'(tx_fifo.size());
      if(submissions_done && status_index==descriptors.size()) sink_hold=0;
      else if(tx_fifo.size()>=16) sink_hold=0;
      else if(tx_fifo.size()<=2) sink_hold=1;
      sink_pop=!sink_hold && (tx_rng[1:0]!=0);
    end
  end

  // A held competing requester shares the ACTUAL retained owner arbiter.
  bit core_outstanding=0,core_accepted=0;
  always @(negedge user_clk) begin
    if(!common_cold_reset_n) begin core_read=0;core_accepted=0;end
    else if(core_accepted) begin core_read=0;core_accepted=0;end
    else if(core_enable && !core_read && !core_outstanding) core_read=1;
  end
  always @(posedge user_clk) begin
    if(!common_cold_reset_n) core_outstanding=0;
    else begin
      if(core_read && core_waitrequest && ddr_lock) core_overlaps++;
      if(core_read && !core_waitrequest) begin
        if(core_outstanding) $fatal(1,"duplicate core acceptance");
        core_outstanding=1;core_accepted=1;
      end
      if(core_readdatavalid) begin
        if(!core_outstanding || core_readdataerror) $fatal(1,"misrouted core response");
        for(int k=0;k<64;k++)
          if(core_readdata[k*8+:8]!==byte_at({33'b0,core_address,6'b0}+64'(k)))
            $fatal(1,"core response lane mismatch");
        core_outstanding=0;core_returns++;
      end
    end
  end

  // The backend is an address-dependent read model, not a replacement for any
  // producer dependency. +RESPONSE_DELAY=N chooses arbitrarily long held
  // responses; 0/1/3-cycle patterns and same-edge returns are also exercised.
  int next_delay=0,delay_left=0;
  longint unsigned backend_cycles=0;
  bit pending=0;
  logic delayed_valid=0;
  logic [511:0] pending_data=0,delayed_data=0,current_data;
  wire immediate_valid=common_cold_reset_n && avm_read && !avm_waitrequest &&
                       !pending && !delayed_valid && next_delay==0;
  assign avm_readdatavalid=delayed_valid || immediate_valid;
  assign avm_readdata=delayed_valid ? delayed_data : current_data;
  always_comb begin
    for(int k=0;k<64;k++)
      current_data[k*8+:8]=avm_byteenable[k] ?
        byte_at({33'b0,avm_address,6'b0}+64'(k)) : 8'hxx;
  end
  always @(negedge user_clk) begin
    if(!common_cold_reset_n) avm_waitrequest=1;
    else begin
      backend_rng=backend_rng^(backend_rng<<13);backend_rng=backend_rng^(backend_rng>>17);backend_rng=backend_rng^(backend_rng<<5);
      avm_waitrequest=(backend_rng[2:0]!=0) || pending || delayed_valid;
      backend_cycles++;
      case(backend_cycles%4)
        0:next_delay=0;
        1:next_delay=1;
        2:next_delay=3;
        3:next_delay=response_delay;
      endcase
    end
  end
  always @(posedge user_clk) begin : backend
    beat_t beat;
    logic [63:0] want_mask;
    if(!common_cold_reset_n) begin pending=0;delayed_valid<=0;delay_left=0;end
    else begin
      delayed_valid<=0;
      if(pending) begin
        if(delay_left==0) begin
          delayed_valid<=1;delayed_data<=pending_data;pending=0;delayed_returns++;
        end else delay_left--;
      end
      if((avm_read || avm_write) && avm_waitrequest) backend_stalls++;
      if((avm_read || avm_write) && !avm_waitrequest) begin
        if(!avm_read || avm_write || avm_burstcount!==1'b1)
          $fatal(1,"native read path emitted an invalid backend command");
        if(avm_address==core_address) begin
          if(avm_byteenable!=='1) $fatal(1,"core mask changed");
          core_commands++;
        end else begin
          if(backend_expected.size()==0) $fatal(1,"unowned backend command");
          beat=backend_expected.pop_front();
          want_mask={32'b0,beat.mask} << (32*int'(beat.base[5]));
          if(avm_address!==beat.base[30:6] || avm_byteenable!==want_mask)
            $fatal(1,"backend address/mask mismatch base=%h mask=%h got=%h/%h",
              beat.base,want_mask,avm_address,avm_byteenable);
          backend_commands++;
        end
        if(pending || delayed_valid) $fatal(1,"overlapping backend read");
        if(next_delay==0) immediate_returns++;
        else begin pending=1;pending_data=current_data;delay_left=next_delay-1;end
      end
    end
  end

  assert property (@(posedge pcie_clk) disable iff(!common_cold_reset_n)
    rx_valid |-> rx_ready) else $fatal(1,"D2H_INGRESS_NOT_READY");
  assert property (@(posedge pcie_clk) disable iff(!common_cold_reset_n)
    wr_dma_read_o && wr_dma_wait_request_i |=> wr_dma_read_o &&
      $stable({wr_dma_address_o,wr_dma_burst_count_o,wr_dma_read_byte_enable_o}))
      else $fatal(1,"D2H_NATIVE_HOLD");
  assert property (@(posedge user_clk) disable iff(!common_cold_reset_n)
    avm_read && avm_waitrequest |=> $stable({avm_read,avm_address,avm_byteenable,avm_burstcount}))
      else $fatal(1,"D2H_BACKEND_HOLD");
  assert property (@(posedge pcie_clk) disable iff(!common_cold_reset_n)
    quarantine_started && fault |=> fault && wr_dma_wait_request_i && !wr_dma_read_data_valid_i)
      else $fatal(1,"D2H_COMMAND_QUARANTINE_ESCAPE");

  task automatic submit(input logic [63:0] src,input logic [63:0] dst,input int words,input bit invalid=0);
    logic [64:0] src_end,dst_end;
    src_end={1'b0,src}+65'(4*words);dst_end={1'b0,dst}+65'(4*words);
    if(words<1 || words>262143 || src[1:0]!=0 || dst[1:0]!=0 || dst_end[64])
      $fatal(1,"D2H_FIXTURE_DESCRIPTOR_FORMAT");
    if(!invalid && src_end>65'h080000000) $fatal(1,"D2H_FIXTURE_SOURCE_RANGE");
    @(negedge pcie_clk);
    // Native ingress writes on valid alone; this is a ready-gated pulse,
    // not a decoupled valid held across backpressure.
    while(rx_ready!==1'b1) @(negedge pcie_clk);
    rx_data={1'b0,5'b0,8'(descriptors.size()),18'(words),dst,src};rx_valid=1;
    @(posedge pcie_clk);
    if(rx_ready!==1'b1) $fatal(1,"D2H_DESCRIPTOR_NOT_READY");
    @(negedge pcie_clk);rx_valid=0;rx_data='x;
  endtask

  task automatic drain;
    submissions_done=1;side_enable=0;core_enable=0;
    // Actual protocol/ownership endpoints, never a fixed sleep.
    while(status_index!=descriptors.size() || packet_desc[0]!=descriptors.size() ||
          packet_desc[1]!=descriptors.size() || native_index!=descriptors.size() ||
          metadata_index!=descriptors.size() || complete_pops!=descriptors.size() ||
          tx_fifo.size()!=0 || side_fifo.size()!=0 || side_expected_enqueue.size()!=0 ||
          side_expected_drain.size()!=0 || backend_expected.size()!=0 || return_expected.size()!=0 ||
          busy || owned_beats!=0 || pending || delayed_valid || core_read || core_outstanding ||
          dma.desc_fifo_count!=0 || dma.desc_data_complete_fifo_count!=0 || !dma.header_fifo_empty ||
          !dma.dma_wr_wdalign.data_idle_state || !dma.dma_wr_wdalign.hdr_idle_state ||
          dma.dma_wr_wdalign.wralign_data_wren_reg || dma.dma_wr_wdalign.wralign_data_wren_reg2 ||
          dma.dma_wr_wdalign.wralign_data_wren_reg3 || dma.dma_wr_wdalign.tlp_header_wrreq_reg ||
          !dma.dma_wr_tlpgen.tlpgen_idle_state || tx_write || status_valid ||
          raw_written!=raw_released || raw_written!=longint'(returns) ||
          aligned_written!=aligned_read || aligned_read!=aligned_credited)
      @(negedge pcie_clk);
  endtask

  initial begin : run
    int lengths[$];
    int extra_length;
    bit have_extra;
    logic [63:0] src,dst,host_base;
    if($value$plusargs("CASE=%s",selected_case)) begin end
    if($value$plusargs("SEED=%d",seed)) begin end
    if($value$plusargs("RESPONSE_DELAY=%d",response_delay)) begin end
    if($value$plusargs("GRANT_DELAY=%d",grant_delay)) begin end
    have_extra=$value$plusargs("DESCRIPTOR_DWORDS=%d",extra_length);
    if(seed==0 || response_delay<0 || grant_delay<0 || grant_delay==32'h7fffffff ||
       (have_extra && (extra_length<1 || extra_length>262143))) $fatal(1,"D2H_ARGUMENT");
    if(selected_case!="matrix" && selected_case!="status" && selected_case!="quarantine")
      $fatal(1,"D2H_UNKNOWN_CASE");
    backend_rng=seed;tx_rng=seed^32'h48fa12b7;if(tx_rng==0) tx_rng=1;
    repeat(4) @(negedge pcie_clk);
    common_cold_reset_n=1;
    while(quiesced!==1'b1) @(negedge pcie_clk);
    quiesce=0;
    if(selected_case=="status") begin
      submit(64'h1000,64'h2000,1);drain();
    end else if(selected_case=="quarantine") begin
      // No descriptor admission layer is present. The valid head returns;
      // the next COMMAND must quarantine, without successful descriptor status.
      quarantine=1;
      submit(64'h7ffffffc,64'h00000012_34560000,2,1);
      while(!fault) @(negedge pcie_clk);
      while(busy || owned_beats!=0 || pending || delayed_valid || return_expected.size()!=0 || backend_expected.size()!=0)
        @(negedge pcie_clk);
      if(fault_code!==4'd1 || fault_address!==64'h80000000 || backend_commands!=1 || returns!=1 ||
         status_index!=0 || packet_desc[0]!=0 || wr_dma_wait_request_i!==1'b1)
        $fatal(1,"D2H_QUARANTINE_BOUNDARY");
      quarantine_started=1;
      // A core completion supplies an event-driven sticky-fault observation.
      core_enable=1;
      while(core_returns==0) @(negedge user_clk);
      core_enable=0;
      while(core_read || core_outstanding) @(negedge user_clk);
      if(!fault || wr_dma_read_data_valid_i || backend_commands!=1 || returns!=1 || status_index!=0)
        $fatal(1,"D2H_QUARANTINE_ESCAPE");
      $display("NATIVE_D2H_QUARANTINE_PASS partial_head=1 descriptor_admission=unqualified");
      $finish;
    end else begin
      lengths='{1,2,3,4,5,7,8,9,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,511,512,513,4095,4096,4097,8193};
      core_enable=1;
      for(int mps=0;mps<2;mps++) begin
        // Change CSR only after header/data machines and all queues drain.
        devcsr=32'(mps<<5);submissions_done=0;side_enable=1;core_enable=1;
        for(int width64=0;width64<2;width64++) begin
          host_base=width64?64'h00000012_34560000:64'h20000000;
          for(int half=0;half<2;half++) for(int so=0;so<8;so++) for(int dest=0;dest<8;dest++) begin
            src=64'h1000+64'(half*32+so*4);
            for(int k=0;k<9;k++) begin
              dst=host_base+64'(dest*4);submit(src,dst,lengths[k]);
            end
            submit(src,host_base+64'hfc0+64'(dest*4),int'(32*(mps+1))+9);
            submit(src,host_base+64'hfe0+64'(dest*4),129);
          end
          for(int so=0;so<8;so++) begin
            foreach(lengths[k]) submit(64'h4000+64'(so*4),host_base+64'hfc0+64'(((so+3)%8)*4),lengths[k]);
            // Full 18-bit limit at all eight source offsets, both half-lines,
            // both MPS settings and both header formats. No reset between them.
            for(int half=0;half<2;half++)
              submit(64'h2000+64'(half*32+so*4),host_base+64'hfe0+64'(((so+5)%8)*4),262143);
            if(have_extra) submit(64'h8000+64'(so*4),host_base+64'(so*4),extra_length);
          end
        end
        // A descriptor crossing 4GiB must change header format without aliasing.
        for(int so=0;so<8;so++) submit(64'h6000+64'(so*4),64'hffffffc0+64'(so*4),129);
        drain();
      end
      core_enable=0;
      while(core_read || core_outstanding) @(negedge user_clk);
      if(core_commands!=core_returns || core_returns==0 || core_overlaps==0 || side_generated==0 ||
         side_reads!=side_generated || side_packets[0]!=side_generated || side_packets[1]!=side_generated ||
         native_stalls==0 || backend_stalls==0 || grant_stalls==0 || tx_pressure_cycles==0 ||
         hp_cycles==0 || immediate_returns==0 || delayed_returns==0 || status_while_queued==0 ||
         raw_wraps<2 || aligned_wraps<2)
        $fatal(1,"D2H_COVERAGE_MISSING");
    end
    if(backend_commands!=returns || packet_count[0]!=packet_count[1] || in_packet[0] || in_packet[1])
      $fatal(1,"D2H_FINAL_COUNTS");
    $display("NATIVE_D2H_PACKETIZER_PASS descriptors=%0d packets=%0d native=%0d backend=%0d raw=%0d raw_release=%0d aligned=%0d credited=%0d raw_wraps=%0d aligned_wraps=%0d tx_highwater=%0d side=%0d core=%0d statuses=%0d status_while_queued=%0d",
      descriptors.size(),packet_count[0],native_commands,backend_commands,raw_written,raw_released,
      aligned_written,aligned_credited,raw_wraps,aligned_wraps,tx_highwater,side_generated,core_returns,status_index,status_while_queued);
    $finish;
  end
endmodule
