`timescale 1ns/1ps
// Compile the EXACT private altpcieav_dma_wr_readmem_2 and its real FIFO,
// lpm_add_sub, and altsyncram dependencies. This test supplies no IP stubs.
// It qualifies the producer's Avalon reads, adapter, retained owner mux, and
// raw-buffer lane order. The downstream PCIe TLP generator is not instantiated.
module native_unaligned_head_tb;
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
  dma_memory_path_unaligned_candidate dut(.*);

  logic [159:0] rx_data=0;
  logic rx_valid=0;
  wire rx_ready;
  logic raw_release=0;
  logic [8:0] raw_release_size=1,raw_read_address=0;
  wire [255:0] raw_read_data;
  logic tlp_desc_pop=0,complete_pop=0;
  wire [159:0] tlp_desc_data;
  wire [2:0] tlp_desc_count;
  wire [9:0] raw_limit;
  wire [4:0] complete_count;
  altpcieav_dma_wr_readmem_2 producer (
    .Clk_i(pcie_clk),.Srst_i(!common_cold_reset_n),
    .WrDmaRead_o(wr_dma_read_o),.WrDmaAddress_o(wr_dma_address_o),
    .WrDmaReadByteEnable_o(wr_dma_read_byte_enable_o),
    .WrDmaBurstCount_o(wr_dma_burst_count_o),
    .WrDmaWaitRequest_i(wr_dma_wait_request_i),
    .WrDmaReadDataValid_i(wr_dma_read_data_valid_i),
    .WrDmaReadData_i(wr_dma_read_data_i),
    .WrDmaRxData_i(rx_data),.WrDmaRxValid_i(rx_valid),.WrDmaRxReady_o(rx_ready),
    .RawBuffRelease_i(raw_release),.RawBuffReleaseSize_i(raw_release_size),
    .DataRamReadAddr_i(raw_read_address),.DataRamReadData_o(raw_read_data),
    .TLPGenDescFifoRdReq_i(tlp_desc_pop),.TLPGenDescFifoDataq_o(tlp_desc_data),
    .TLPGenDescFifoCount_o(tlp_desc_count),.TLPGenBuffLimit_o(raw_limit),
    .DescDataCompleteFifoRdReq_i(complete_pop),
    .DescDataCompleteFifoCount_o(complete_count));

  typedef struct packed {
    logic [63:0] base;
    logic [31:0] mask;
  } beat_t;
  beat_t backend_expected[$],return_expected[$],raw_expected[$];
  bit descriptor_active=0,expected_fault=0,core_enable=0;
  logic [63:0] model_src=0;
  int unsigned model_remaining=0;
  int cases=0,negative_cases=0,native_commands=0,dma_commands=0,returns=0;
  int raw_words=0,core_commands=0,core_returns=0,core_overlaps=0;
  int native_stalls=0,backend_stalls=0,immediate_returns=0,delayed_returns=0;
  logic [7:0] descriptor_id=0;

  function automatic logic [7:0] byte_at(input logic [63:0] address);
    // Depend on high address bits as well as lane number; do not model a
    // truncated/wrapping RAM that could conceal an aperture alias.
    logic [63:0] mixed;
    mixed=address^(address>>9)^(address>>17)^(address>>31)^(address>>47);
    return 8'(mixed)^8'h96;
  endfunction
  function automatic logic [31:0] span_mask(input int first,input int bytes);
    logic [31:0] result;
    result='0;
    for(int k=0;k<32;k++) if(k>=first && k<first+bytes) result[k]=1;
    return result;
  endfunction

  // Independent descriptor model: compare commands even while stalled, then
  // create ownership records only at the actual !waitrequest acceptance edge.
  always @(posedge pcie_clk) begin : native_scoreboard
    int take_dw,want_beats,offset;
    logic [31:0] want_mask;
    logic [64:0] end_exclusive;
    beat_t beat;
    if(common_cold_reset_n) begin
      if(mux_fault || (fault && !expected_fault))
        $fatal(1,"unexpected native-path fault code=%0d address=%h",fault_code,fault_address);
      if(wr_dma_read_o) begin
        if(!descriptor_active || model_remaining==0)
          $fatal(1,"producer emitted an extra command");
        offset=int'(model_src[4:0]);
        if(offset!=0) begin
          take_dw=(model_remaining < (32-offset)/4) ? int'(model_remaining) : (32-offset)/4;
          want_beats=1;want_mask=span_mask(offset,4*take_dw);
        end else if(model_remaining>=128) begin
          take_dw=128;want_beats=16;want_mask='1;
        end else if(model_remaining<8) begin
          take_dw=int'(model_remaining);want_beats=1;want_mask=span_mask(0,4*take_dw);
        end else begin
          want_beats=int'(model_remaining)/8;take_dw=8*want_beats;want_mask='1;
        end
        if(wr_dma_address_o!==model_src || wr_dma_burst_count_o!==5'(want_beats) ||
           wr_dma_read_byte_enable_o!==want_mask)
          $fatal(1,"native segmentation mismatch src=%h remaining=%0d got=%h/%0d/%h expected=%h/%0d/%h",
            model_src,model_remaining,wr_dma_address_o,wr_dma_burst_count_o,
            wr_dma_read_byte_enable_o,model_src,want_beats,want_mask);
        if(wr_dma_wait_request_i) native_stalls++;
        else begin
          end_exclusive={1'b0,model_src[63:5],5'b0}+65'(want_beats*32);
          if(end_exclusive>65'h080000000)
            $fatal(1,"out-of-aperture native command was accepted");
          for(int j=0;j<want_beats;j++) begin
            beat.base={model_src[63:5],5'b0}+64'(j*32);beat.mask=want_mask;
            backend_expected.push_back(beat);
            return_expected.push_back(beat);
            raw_expected.push_back(beat);
          end
          model_src=model_src+64'(4*take_dw);
          model_remaining=model_remaining-int'(take_dw);
          native_commands++;
        end
      end
      if(wr_dma_read_data_valid_i) begin
        if(return_expected.size()==0) $fatal(1,"unowned native return");
        beat=return_expected.pop_front();
        for(int k=0;k<32;k++)
          if(beat.mask[k] && wr_dma_read_data_i[k*8+:8]!==byte_at(beat.base+64'(k)))
            $fatal(1,"native response was shifted or corrupted base=%h lane=%0d",beat.base,k);
        returns++;
      end
    end
  end

  // Exercise the producer's actual raw RAM with its advertised credit counter.
  // The one rising edge between address presentation and checking is the real
  // altsyncram ADDRESS_REG_B=CLOCK0 interface, not a guessed drain delay.
  logic [9:0] raw_consumed=0;
  logic [8:0] raw_slot=0;
  int raw_state=0;
  always @(negedge pcie_clk) begin : raw_consumer
    beat_t beat;
    if(!common_cold_reset_n) begin
      raw_consumed=0;raw_slot=0;raw_state=0;raw_release=0;raw_read_address=0;
    end else case(raw_state)
      0: begin
        raw_release=0;
        if(raw_limit!=raw_consumed) begin raw_read_address=raw_slot;raw_state=1;end
      end
      1: begin
        if(raw_expected.size()==0) $fatal(1,"raw-buffer credit without ownership");
        beat=raw_expected.pop_front();
        for(int k=0;k<32;k++)
          if(beat.mask[k] && raw_read_data[k*8+:8]!==byte_at(beat.base+64'(k)))
            $fatal(1,"native raw-buffer lane mismatch slot=%0d base=%h lane=%0d",raw_slot,beat.base,k);
        raw_words++;raw_consumed=raw_consumed+1'b1;raw_slot=raw_slot+1'b1;
        raw_release=1;raw_release_size=1;raw_state=2;
      end
      2: begin raw_release=0;raw_state=0;end
      default: $fatal(1,"raw consumer state");
    endcase
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
  int response_delay=19,next_delay=0,delay_left=0,backend_cycles=0;
  int unsigned rng=32'h62bd9317;
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
      rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
      avm_waitrequest=(rng[2:0]!=0);
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
          dma_commands++;
        end
        if(pending || delayed_valid) $fatal(1,"overlapping backend read");
        if(next_delay==0) immediate_returns++;
        else begin pending=1;pending_data=current_data;delay_left=next_delay-1;end
      end
    end
  end

  assert property (@(posedge pcie_clk) disable iff(!common_cold_reset_n)
    wr_dma_read_o && wr_dma_wait_request_i |=> wr_dma_read_o &&
      $stable({wr_dma_address_o,wr_dma_burst_count_o,wr_dma_read_byte_enable_o}))
    else $fatal(1,"native command changed under backpressure");
  assert property (@(posedge user_clk) disable iff(!common_cold_reset_n)
    avm_read && avm_waitrequest |=>
      $stable({avm_read,avm_address,avm_byteenable,avm_burstcount}))
    else $fatal(1,"backend command changed under backpressure");

  task automatic cold_reset;
    core_enable=0;
    @(negedge pcie_clk);
    common_cold_reset_n=0;quiesce=1;descriptor_active=0;expected_fault=0;
    rx_valid=0;tlp_desc_pop=0;complete_pop=0;model_remaining=0;
    backend_expected.delete();return_expected.delete();raw_expected.delete();
    repeat(4) @(negedge pcie_clk);
    common_cold_reset_n=1;
    // Use the adapter's qualification indication; no guessed startup interval.
    while(quiesced!==1'b1) @(negedge pcie_clk);
    quiesce=0;
  endtask
  task automatic submit_descriptor(input logic [63:0] src,input logic [63:0] dst,
                                   input int words,input bit want_fault);
    if(words<1 || words>262143 || src[1:0]!=0 || dst[1:0]!=0)
      $fatal(1,"test descriptor violates stated native legality assumptions");
    while(rx_ready!==1'b1) @(negedge pcie_clk);
    @(negedge pcie_clk);
    model_src=src;model_remaining=words;descriptor_active=1;expected_fault=want_fault;
    rx_data={1'b0,5'b0,descriptor_id,18'(words),dst,src};rx_valid=1;
    @(posedge pcie_clk);
    if(rx_ready!==1'b1) $fatal(1,"descriptor producer was not ready");
    @(negedge pcie_clk);rx_valid=0;rx_data='x;
  endtask
  task automatic good_descriptor(input logic [63:0] src,input logic [63:0] dst,
                                 input int words);
    int beats,before_dma,before_returns,before_raw;
    logic [159:0] want_descriptor;
    beats=(int'(src[4:0])+4*words+31)/32;
    before_dma=dma_commands;before_returns=returns;before_raw=raw_words;
    want_descriptor={1'b0,5'b0,descriptor_id,18'(words),dst,16'b0,16'(beats),src[31:0]};
    submit_descriptor(src,dst,words,0);
    // Check metadata as soon as the producer advertises it. In particular,
    // +DESCRIPTOR_DWORDS can expose the vendor's 18b adjusted_dw overflow
    // immediately instead of waiting forever for its incorrect done count.
    while(tlp_desc_count!==3'd1) @(negedge pcie_clk);
    if(tlp_desc_data!==want_descriptor)
      $fatal(1,"early descriptor metadata mismatch got=%h want=%h",tlp_desc_data,want_descriptor);
    while(complete_count!==5'd1 || tlp_desc_count!==3'd1 || busy!==1'b0 || raw_expected.size()!=0)
      @(negedge pcie_clk);
    if(model_remaining!=0 || backend_expected.size()!=0 || return_expected.size()!=0 ||
       dma_commands-before_dma!=beats || returns-before_returns!=beats ||
       raw_words-before_raw!=beats || fault || mux_fault)
      $fatal(1,"native descriptor did not complete exactly");
    if(tlp_desc_data!==want_descriptor)
      $fatal(1,"source/destination/length/id passthrough mismatch got=%h want=%h",
        tlp_desc_data,want_descriptor);
    tlp_desc_pop=1;complete_pop=1;
    @(negedge pcie_clk);tlp_desc_pop=0;complete_pop=0;
    while(tlp_desc_count!=0 || complete_count!=0) @(negedge pcie_clk);
    descriptor_active=0;descriptor_id=descriptor_id+1'b1;cases++;
  endtask
  task automatic bad_descriptor(input logic [63:0] src,input int words,
                                input logic [63:0] bad_address,input int accepted_beats);
    int before_dma,before_returns,before_raw;
    cold_reset();
    before_dma=dma_commands;before_returns=returns;before_raw=raw_words;
    submit_descriptor(src,64'h00000012_34560014,words,1);
    while(!fault) @(negedge pcie_clk);
    // A crossing descriptor may already have completed a valid final head;
    // validate that owned data through the raw RAM before inspecting counts.
    while(raw_expected.size()!=0) @(negedge pcie_clk);
    if(fault_code!==4'd1 || fault_address!==bad_address || mux_fault || busy || owned_beats!=0 ||
       backend_expected.size()!=0 || return_expected.size()!=0 ||
       dma_commands-before_dma!=accepted_beats || returns-before_returns!=accepted_beats ||
       raw_words-before_raw!=accepted_beats)
      $fatal(1,"native aperture rejection/count/diagnostic mismatch");
    // This is a sticky-fault observation, not a drain/recovery mechanism.
    repeat(9) begin
      @(negedge pcie_clk);
      if(!fault || !wr_dma_wait_request_i || wr_dma_read_data_valid_i || avm_read || avm_write)
        $fatal(1,"invalid descriptor escaped quarantine");
    end
    negative_cases++;
  endtask

  initial begin : run
    int head_words,descriptor_dwords;
    bit extended_requested;
    logic [63:0] source,destination;
    extended_requested=0;
    if($value$plusargs("RESPONSE_DELAY=%d",response_delay)) begin end
    if($value$plusargs("SEED=%d",rng)) begin end
    if($value$plusargs("DESCRIPTOR_DWORDS=%d",descriptor_dwords)) begin
      if(descriptor_dwords<1 || descriptor_dwords>262143)
        $fatal(1,"DESCRIPTOR_DWORDS must be nonzero and fit the native 18b field");
      extended_requested=1;
    end
    if(response_delay<0 || rng==0) $fatal(1,"invalid delay/seed");
    cold_reset();core_enable=1;
    for(int half=0;half<2;half++) begin
      for(int offset_dw=0;offset_dw<8;offset_dw++) begin
        source=64'h1000+64'(half*32+offset_dw*4);
        // Source and destination offsets vary independently. The 64b host
        // destination is deliberately outside the local DDR aperture.
        for(int dst_dw=0;dst_dw<8;dst_dw++)
          good_descriptor(source,64'h00000012_34560000+64'(dst_dw*4),9);
        destination=64'h00000012_34560000+64'(((offset_dw+3)%8)*4);
        head_words=8-offset_dw;
        good_descriptor(source,destination,1);
        if(head_words>1) good_descriptor(source,destination,head_words-1);
        good_descriptor(source,destination,head_words);
        good_descriptor(source,destination,head_words+1);
        good_descriptor(source,destination,head_words+7);
        good_descriptor(source,destination,head_words+8);
        good_descriptor(source,destination,head_words+9);
        good_descriptor(source,destination,127);
        good_descriptor(source,destination,128);
        good_descriptor(source,destination,129);
        good_descriptor(source,destination,head_words+127);
        good_descriptor(source,destination,head_words+128);
        good_descriptor(source,destination,head_words+129);
        good_descriptor(source,destination,head_words+255);
        good_descriptor(source,destination,head_words+256);
        good_descriptor(source,destination,head_words+257);
        // Every DWORD start in both halves of the final 64b-addressed line.
        source=64'h7fffffc0+64'(half*32+offset_dw*4);
        good_descriptor(source,destination,1);
        good_descriptor(source,destination,int'((64'h80000000-source)/4));
      end
    end
    if(extended_requested)
      for(int half=0;half<2;half++)
        for(int offset_dw=0;offset_dw<8;offset_dw++)
          good_descriptor(64'h2000+64'(half*32+offset_dw*4),
            64'h00000012_34560000+64'(((offset_dw+5)%8)*4),descriptor_dwords);
    core_enable=0;
    while(core_read || core_outstanding) @(negedge user_clk);
    if(core_commands!=core_returns || core_returns==0 || core_overlaps==0 ||
       native_stalls==0 || backend_stalls==0 || immediate_returns==0 || delayed_returns==0)
      $fatal(1,"native contention/stall/latency coverage missing");
    // Reject crossing aligned bursts before ANY backend request.
    bad_descriptor(64'h7fffffe0,16,64'h7fffffe0,0);
    bad_descriptor(64'h7fffffc0,128,64'h7fffffc0,0);
    // Descriptor length is not an adapter input: the valid final head is
    // accepted, then the next command is rejected at its original address.
    bad_descriptor(64'h7ffffffc,2,64'h80000000,1);
    bad_descriptor(64'h7fffffc0,17,64'h80000000,2);
    bad_descriptor(64'h80000000,1,64'h80000000,0);
    bad_descriptor(64'h100000004,1,64'h100000004,0);
    bad_descriptor(64'hfffffffffffffffc,1,64'hfffffffffffffffc,0);
    if(dma_commands!=returns || returns!=raw_words)
      $fatal(1,"native end-to-end ownership count mismatch");
    $display("NATIVE_UNALIGNED_HEAD_PASS cases=%0d negative=%0d native_commands=%0d backend=%0d returns=%0d raw=%0d core=%0d overlaps=%0d native_stalls=%0d backend_stalls=%0d immediate=%0d delayed=%0d",
      cases,negative_cases,native_commands,dma_commands,returns,raw_words,
      core_returns,core_overlaps,native_stalls,backend_stalls,immediate_returns,delayed_returns);
    $finish;
  end
endmodule
