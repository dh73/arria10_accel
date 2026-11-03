// SPDX-License-Identifier: BSD-3-Clause
// Handshake-based stimulus; a queue becoming empty is never a retirement event.
task automatic csr(input logic [7:0] address,input logic [31:0] value);
  bit accepted;
  @(negedge pcie_clk); #1;
  cs=1;cswrite=1;csread=0;csaddr=address;csdata=value;
  do begin
    @(posedge pcie_clk);accepted=(cswait===1'b0);
    @(negedge pcie_clk);#1;
  end while(!accepted);
  cs=0;cswrite=0;
endtask

task automatic csr_read_control(input logic [31:0] expected);
  bit accepted;
  @(negedge pcie_clk);#1;cs=1;csread=1;cswrite=0;csaddr=8'h18;
  do begin
    @(posedge pcie_clk);accepted=(cswait===1'b0);
    @(negedge pcie_clk);#1;
  end while(!accepted);
  if(csreaddata!==expected) $fatal(1,"D2H_DCS_READBACK");
  cs=0;csread=0;
endtask

task automatic submit_id(input int id,input logic [63:0] src,
                         input logic [63:0] dst,input int words);
  bit accepted;
  logic [64:0] src_end,dst_end;
  src_end={1'b0,src}+65'(4*words);dst_end={1'b0,dst}+65'(4*words);
  if(id<0 || id>127 || words<1 || words>262143 || src[1:0]!=0 || dst[1:0]!=0 ||
     src_end>65'h080000000 || dst_end[64]) $fatal(1,"D2H_DTS_DESCRIPTOR_FORMAT");
  @(negedge pcie_clk);#1;
  dtscs=1;dtswrite=1;dtsdata={96'b0,6'b0,8'(id),18'(words),dst,src};
  do begin
    @(posedge pcie_clk);accepted=(dtswait===1'b0);
    @(negedge pcie_clk);#1;
  end while(!accepted);
  dtscs=0;dtswrite=0;dtsdata='x;
endtask

task automatic submit(input logic [63:0] src,input logic [63:0] dst,input int words);
  submit_id((dts_accepted*37)%128,src,dst,words);
endtask

task automatic accept_fetch(input int first,input int count,input logic [63:0] source);
  while(!fetch_req) @(negedge pcie_clk);
  @(negedge pcie_clk);#1;
  if(first_id!==8'(first) || fetch_data!==
       {6'b0,8'(192+(fetch_accepts%64)),18'(count*8),64'h1000,source})
    $fatal(1,"D2H_FETCH_SNAPSHOT first=%0d count=%0d data=%h",first,count,fetch_data);
  fetch_ack=1;
  @(posedge pcie_clk);@(negedge pcie_clk);#1;fetch_ack=0;
endtask

task automatic configure(input logic [63:0] header,input int last_id,
                         input bit report_all,input bit enable_msi);
  if(header[1:0]!=0 || header>64'hffff_ffff_ffff_fe03 || last_id<0 || last_id>127)
    $fatal(1,"D2H_HEADER_APERTURE");
  // The low destination write initializes the real descriptor-table address.
  csr(8'h04,header[63:32]);csr(8'h00,header[31:0]);
  csr(8'h0c,0);csr(8'h08,32'h1000);csr(8'h14,32'(last_id));
  csr(8'h18,32'(report_all));
  msi_interface={1'b0,enable_msi,16'h49a2,64'h00000000_fee01040};
  quiesce=0;submissions_done=0;
endtask

task automatic new_epoch;
  @(negedge pcie_clk);#1;
  common_cold_reset_n=0;quiesce=1;cs=0;cswrite=0;csread=0;dtscs=0;dtswrite=0;
  fetch_ack=0;core_enable=0;side_enable=0;host_hold=1;inject_failure=0;
  descriptors.delete();backend_expected.delete();return_expected.delete();
  side_fifo.delete();side_expected_enqueue.delete();side_expected_drain.delete();
  host_expected.delete();ingress_expected.delete();
  native_index=0;metadata_index=0;status_index=0;
  for(int m=0;m<2;m++) begin
    packet_desc[m]=0;in_packet[m]=0;packet_words[m]=0;packet_start[m]=0;
    packet_beats[m]=0;packet_beat[m]=0;packet_seen[m]=0;packet_address[m]=0;
    packet_count[m]=0;side_packets[m]=0;
  end
  expected_header=0;expected_control=0;expected_endpoints=0;
  accepted_descriptors=0;dts_accepted=0;host_accepted=0;host_expected_count=0;
  status_writes=0;msi_writes=0;fetch_accepts=0;
  host_stalls=0;msi_stalls=0;status_during_stall=0;ingress_stalls=0;
  credit_stalls=0;configuration_stalls=0;doorbell_handoffs=0;base_change_armed=0;
  host_was_held=0;controller_was_held=0;fetch_was_held=0;
  side_sequence=0;side_reads=0;side_generated=0;tx_highwater=0;
  native_commands=0;backend_commands=0;returns=0;complete_pops=0;
  core_commands=0;core_returns=0;core_overlaps=0;
  native_stalls=0;backend_stalls=0;grant_stalls=0;tx_pressure_cycles=0;hp_cycles=0;
  immediate_returns=0;delayed_returns=0;status_while_queued=0;
  raw_written=0;raw_released=0;aligned_written=0;aligned_read=0;aligned_credited=0;
  prev_raw_limit=0;prev_aligned_limit=0;raw_wraps=0;aligned_wraps=0;
  submissions_done=0;sink_hold=1;devcsr=0;msi_interface=0;
  // Fixed reset width only; no success or retirement relies on this delay.
  repeat(4) @(negedge pcie_clk);
  #1;common_cold_reset_n=1;epochs++;
  while(quiesced!==1'b1) @(negedge pcie_clk);
  if(dcm_write || retirement_fault || retirement_busy || status_valid)
    $fatal(1,"D2H_RESET_GHOST_OWNER");
  quiesce=0;
endtask

task automatic finish_epoch;
  host_hold=0;submissions_done=1;side_enable=0;core_enable=0;
  // First close the DTS-to-native admission boundary. A native-only drain can
  // otherwise finish during a gap before a queued controller offer is issued.
  while(ingress_expected.size()!=0 || accepted_descriptors!=dts_accepted)
    @(negedge pcie_clk);
  drain(); // Preserved exact native byte/command/status/credit oracles.
  while(host_expected.size()!=0 || ingress_expected.size()!=0 || retirement_busy ||
        dcm_write || controller_valid || fetch_req || controller.dt_fifo_count!=0 ||
        controller.dma_tx_state!=6'h01 || controller.dma_status_valid_reg)
    @(negedge pcie_clk);
  if(retirement_fault || host_accepted!=host_expected_count ||
     dts_accepted!=accepted_descriptors || accepted_descriptors!=descriptors.size() ||
     packet_count[0]!=packet_count[1] || backend_commands!=returns || in_packet[0] || in_packet[1])
    $fatal(1,"D2H_COMPOSITION_FINAL_COUNTS");
  quiesce=1;
  while(!quiesced) @(negedge pcie_clk);
  if(busy || owned_beats!=0 || ddr_lock) $fatal(1,"D2H_MEMORY_NOT_QUIESCENT");
endtask

task automatic capacity_phase;
  configure(64'h00000012_34567000,127,1,1);
  csr(8'h10,63);while(!fetch_req) @(negedge pcie_clk);
  csr(8'h10,127);
  accept_fetch(0,64,64'h00000012_34567200);
  accept_fetch(64,64,64'h00000012_34567a00);
  core_enable=1;side_enable=1;
  for(int i=0;i<128;i++)
    submit_id((i*37)%128,64'h2000+64'((i%16)*4),
              64'h00000012_45670fe0+64'((i%8)*4),1+(i%17));
  while(status_index!=128) @(negedge pcie_clk);
  submit_id(0,64'h403c,64'hfffffffc,129);
`ifndef D2H_ORIGINAL_CONTROLLER
  while(controller.c1_pending!=0 || credit_stalls==0) @(negedge pcie_clk);
  if(controller.c1_reserved!=128 || controller.c1_completed!=128 || host_accepted!=0)
    $fatal(1,"D2H_RESERVED_CAPACITY_NOT_REACHED");
  fork
    csr(8'h00,32'h34569000);
    begin
      while(controller.dcs_current_state!=4'b0100 || !cswrite) @(negedge pcie_clk);
      if(!cswait || expected_header!==64'h00000012_34567000)
        $fatal(1,"D2H_CONFIG_RETAGGED_LIVE_WORK");
      // Live MSI inputs change during the held old-generation status write.
      msi_interface={1'b0,1'b0,16'habcd,64'h00000001_fee02040};
      host_hold=0;
    end
  join
  finish_epoch();
  if(status_writes!=129 || msi_writes!=2 || fetch_accepts!=2 ||
     credit_stalls==0 || status_during_stall==0 || host_stalls==0 || msi_stalls==0)
    $fatal(1,"D2H_CAPACITY_COVERAGE");
`else
  // Check the original FIFO write offer before its next acceptance edge.
  while(controller.ep_last_fifo_wrreq || controller.dma_status_valid_reg ||
        status_index!=129 || controller.ep_last_fifo_count<=128) @(negedge pcie_clk);
  $fatal(1,"D2H_EXPECTED_CAPACITY_WITNESS_MISSING");
`endif
endtask

task automatic queued_boundary;
  logic [63:0] header;
  header=64'h00000056_12348000;
  configure(header,127,1,1);host_hold=0;
  csr(8'h10,63);while(!fetch_req) @(negedge pcie_clk);csr(8'h10,127);
  accept_fetch(0,64,header+64'h200);
  for(int id=0;id<64;id++) submit_id(id,64'h3000+64'(id*4),64'h4000+64'(id*4),1);
  // The lower half has actually retired before endpoints for its next
  // generation are armed; no old unadmitted same-ID occurrence is present.
  submissions_done=1;
  while(accepted_descriptors!=dts_accepted) @(negedge pcie_clk);
  drain();
  while(retirement_busy || host_expected.size()!=0 || dcm_write) @(negedge pcie_clk);
  csr(8'h10,31); // Occupies the original one-entry pending doorbell slot.
  if(!controller.pending_desc_id_stored || controller.pending_desc_id_reg!=31)
    $fatal(1,"D2H_PENDING_DOORBELL_NOT_STORED");
  fork
    csr(8'h10,63);
    begin
      while(controller.dcs_current_state!=4'b0100 || !cswrite) @(negedge pcie_clk);
      if(!cswait || !controller.pending_desc_id_stored || controller.pending_desc_id_reg!=31)
        $fatal(1,"D2H_PENDING_DOORBELL_OVERWRITE");
      // Phase alignment makes the held DCS write reach ACK on the automatic
      // saved-pointer handoff edge; a boundary-flag-only gate would lose 31.
      while(controller.dcs_current_state!=4'b0001) @(negedge pcie_clk);
      accept_fetch(64,64,header+64'ha00);
    end
  join
  // Both the saved pointer and the later held bus write must survive handoff.
  accept_fetch(0,32,header+64'h200);
  accept_fetch(32,32,header+64'h600);
  submissions_done=0;
  for(int id=64;id<128;id++) submit_id(id,64'h5000+64'(id*4),64'h6000+64'(id*4),1);
  for(int id=0;id<64;id++) submit_id(id,64'h7000+64'(id*4),64'h8000+64'(id*4),1);
  finish_epoch();
endtask

task automatic packet_matrix;
  int lengths[$];
  int extra_length;
  bit have_extra;
  logic [63:0] src,dst,host_base;
  have_extra=$value$plusargs("DESCRIPTOR_DWORDS=%d",extra_length);
  if(have_extra && (extra_length<1 || extra_length>262143)) $fatal(1,"D2H_ARGUMENT");
  lengths='{1,2,3,4,5,7,8,9,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,511,512,513,4095,4096,4097,8193};
  for(int mps=0;mps<2;mps++) begin
    configure(64'h00000020_00008000+64'(mps*4096),127,1,0);
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
        for(int half=0;half<2;half++)
          submit(64'h2000+64'(half*32+so*4),host_base+64'hfe0+64'(((so+5)%8)*4),262143);
        if(have_extra) submit(64'h8000+64'(so*4),host_base+64'(so*4),extra_length);
      end
    end
    for(int so=0;so<8;so++) submit(64'h6000+64'(so*4),64'hffffffc0+64'(so*4),129);
    finish_epoch();
  end
  if(core_commands!=core_returns || core_returns==0 || core_overlaps==0 || side_generated==0 ||
     side_reads!=side_generated || side_packets[0]!=side_generated || side_packets[1]!=side_generated ||
     native_stalls==0 || backend_stalls==0 || grant_stalls==0 || tx_pressure_cycles==0 || hp_cycles==0 ||
     immediate_returns==0 || delayed_returns==0 || status_while_queued==0 || raw_wraps<2 || aligned_wraps<2 ||
     status_writes!=accepted_descriptors || ingress_stalls==0)
    $fatal(1,"D2H_COMPOSITION_STRESS_COVERAGE");
endtask

initial begin : composition_run
  int before_status,before_msi;
  logic [63:0] header;
  if($value$plusargs("CASE=%s",selected_case)) begin end
  if($value$plusargs("SEED=%d",seed)) begin end
  if($value$plusargs("RESPONSE_DELAY=%d",response_delay)) begin end
  if($value$plusargs("GRANT_DELAY=%d",grant_delay)) begin end
  if(seed==0 || response_delay<0 || grant_delay<0 || grant_delay==32'h7fffffff)
    $fatal(1,"D2H_ARGUMENT");
  backend_rng=seed;tx_rng=seed^32'h48fa12b7;if(tx_rng==0) tx_rng=1;
  host_rng=seed^32'h25ca7631;if(host_rng==0) host_rng=1;
  new_epoch();
  case(selected_case)
    "capacity-witness": capacity_phase();
    "base-witness": begin
      configure(64'h00000012_34567000,127,1,0);
      submit_id(9,64'h1004,64'h2004,1);
      while(!dcm_write) @(negedge pcie_clk);
      csr(8'h00,32'h34569000);
      while(dcm_write) @(negedge pcie_clk);
      $fatal(1,"D2H_EXPECTED_BASE_WITNESS_MISSING");
    end
    "failure-witness", "failure": begin
      configure(64'h00000012_34567000,127,1,0);
      inject_failure=1;host_hold=0;
      submit_id(3,64'h103c,64'h2004,17);
      while(status_index!=1) @(negedge pcie_clk);
`ifdef D2H_ORIGINAL_CONTROLLER
      while(!dcm_write) @(negedge pcie_clk);
      @(negedge pcie_clk);
      $fatal(1,"D2H_EXPECTED_FAILURE_WITNESS_MISSING");
`else
      while(!retirement_fault) @(negedge pcie_clk);
      drain();
      csr_read_control(1);
      if(retirement_fault_data!==32'h7d || retirement_expected_id!==8'd3 ||
         controller.c1_reserved!=1 || controller.c1_pending!=1 ||
         controller.c1_completed!=0 || host_accepted!=0 || dcm_write)
        $fatal(1,"D2H_FAILURE_NOT_CONTAINED");
      quiesce=1;while(!quiesced) @(negedge pcie_clk);
      if(!retirement_fault || !retirement_busy) $fatal(1,"D2H_FAILURE_OWNER_LOST");
`endif
    end
    "reset": begin
      configure(64'h00000012_34567000,127,1,0);
      submit_id(3,64'h103c,64'h2004,17);
      submissions_done=1;
      while(!dcm_write || packet_desc[1]!=1 || tx_used!=0) @(negedge pcie_clk);
      quiesce=1;while(!quiesced) @(negedge pcie_clk);
      if(!retirement_busy || host_accepted!=0) $fatal(1,"D2H_QUIESCE_FALSE_RETIREMENT");
      // Common reset cancels this owner; it never completes the stalled write.
      new_epoch();
      configure(64'h00000034_76543000,127,1,0);host_hold=0;
      submit_id(3,64'h203c,64'h00000012_20000004,129);
      finish_epoch();
      if(epochs!=2 || host_accepted!=1) $fatal(1,"D2H_RESET_REUSE");
    end
    "selective": begin
      host_hold=0;
      for(int report_all=0;report_all<2;report_all++) for(int irq=0;irq<2;irq++) begin
        header=64'h00000012_34567000+64'((report_all*2+irq)*4096);
        configure(header,3,1'(report_all),1'(irq));
        csr(8'h10,1);while(!fetch_req) @(negedge pcie_clk);csr(8'h10,3);
        accept_fetch(0,2,header+64'h200);accept_fetch(2,2,header+64'h240);
        before_status=status_writes;before_msi=msi_writes;
        submit_id(2,64'h1000,64'h2000,1);submit_id(0,64'h1024,64'h2004,33);
        submit_id(3,64'h1048,64'h2008,129);submit_id(1,64'h106c,64'h200c,17);
        finish_epoch();
        if(status_writes-before_status!=(report_all?4:2) || msi_writes-before_msi!=(irq?2:0))
          $fatal(1,"D2H_STATUS_INTERRUPT_POLICY");
      end
      queued_boundary();
      if(accepted_descriptors!=208 || fetch_accepts!=12 || status_writes!=204 || msi_writes!=8 ||
         doorbell_handoffs==0)
        $fatal(1,"D2H_QUEUED_BOUNDARY_COUNTS");
    end
    "stress": begin capacity_phase();packet_matrix();end
    default: $fatal(1,"D2H_UNKNOWN_COMPOSITION_CASE");
  endcase
  $display("D2H_COMPOSITION_PASS case=%s descriptors=%0d packets=%0d statuses=%0d status_writes=%0d msi_writes=%0d host_stalls=%0d status_during_stall=%0d credit_stalls=%0d epochs=%0d production_driver_contract_valid=false",
    selected_case,accepted_descriptors,packet_count[0],status_index,status_writes,msi_writes,
    host_stalls,status_during_stall,credit_stalls,epochs);
  $finish;
end
