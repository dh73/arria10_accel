`timescale 1ns/1ps
// Direct command-level qualification of the new adapter with the retained mux.
// The separate native test instantiates the actual write-memory producer.
module line_coalescing_tb;
  logic pcie_clk=0,user_clk=0,common_cold_reset_n=0;
  always #5 pcie_clk=~pcie_clk;
  always #7 user_clk=~user_clk;
  logic app_nreset_status=1,backend_reset_n=1,memory_ready=1,memory_failed=0,quiesce=0;
  logic [63:0] rd_dma_address_o=0,wr_dma_address_o=0;
  logic rd_dma_write_o=0,wr_dma_read_o=0;
  logic [255:0] rd_dma_write_data_o=0;
  logic [31:0] rd_dma_byte_enable_o=0,wr_dma_read_byte_enable_o=0;
  logic [4:0] rd_dma_burst_count_o=1,wr_dma_burst_count_o=1;
  wire rd_dma_wait_request_i,wr_dma_wait_request_i,wr_dma_read_data_valid_i;
  wire [255:0] wr_dma_read_data_i;
  wire busy,quiesced,fault,ddr_lock,mux_fault;
  wire [3:0] fault_code;
  wire [63:0] fault_address;
  wire [4:0] owned_beats;
  logic [24:0] core_address=25'h40;
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
  logic avm_waitrequest=1,avm_readdatavalid,avm_readdataerror;
  logic [511:0] avm_readdata;
  dma_memory_path_line_coalescing_candidate dut(.*);

  // Sparse full-address memory, with defined contents at every aperture byte.
  // No modulo indexing or RAM-size alias is used for the 2 GiB boundary tests.
  logic [7:0] memory_bytes[longint unsigned],reference_bytes[longint unsigned];
  logic [31:0] write_masks[0:15];
  logic [255:0] write_values[0:15];
  bit expected_active=0,expected_write=0;
  logic [63:0] expected_base;
  logic [31:0] expected_mask;
  int expected_beats=0,accepted=0,case_commands=0,pairs=0;
  int cycles=0,dma_commands=0,dma_responses=0,read_accepts=0,write_accepts=0;
  int cases=0,rejections=0,quarantine_cases=0,stalls=0,overlaps=0;
  int core_commands=0,core_responses=0,backend_returns=0;
  bit run_core=0,stop_core=0,core_done=0;
  bit manual_stall=0,inject_error=0,pending=0,pending_error=0;
  int forced_stall=0,max_response_delay=31,delay_override=-1,delay_left=0;
  int response_mode=1; // 0 = combinational return on acceptance; 1 = delayed.
  logic delayed_valid=0,delayed_error=0;
  logic [511:0] delayed_data=0,pending_data=0;
  wire instant_return=common_cold_reset_n && response_mode==0 && avm_read &&
                      !avm_waitrequest && !pending && !delayed_valid;

  function automatic logic [7:0] initial_byte(input longint unsigned addr);
    return 8'(addr ^ (addr>>8) ^ (addr>>16) ^ (addr>>24) ^ 64'ha7);
  endfunction
  function automatic logic [7:0] memory_byte(input longint unsigned addr);
    if(memory_bytes.exists(addr)) return memory_bytes[addr];
    return initial_byte(addr);
  endfunction
  function automatic logic [7:0] reference_byte(input longint unsigned addr);
    if(reference_bytes.exists(addr)) return reference_bytes[addr];
    return initial_byte(addr);
  endfunction
  function automatic logic [511:0] line_data(input logic [24:0] addr,
                                            input logic [63:0] mask);
    longint unsigned base;
    base=64'(addr)<<6;
    for(int k=0;k<64;k++)
      line_data[k*8+:8]=mask[k] ? memory_byte(base+64'(k)) : 8'hxx;
  endfunction
  function automatic logic [31:0] interval_mask(input int offset,input int bytes);
    interval_mask=0;
    for(int k=0;k<32;k++)
      if(k>=offset && k<offset+bytes) interval_mask[k]=1;
  endfunction
  function automatic logic [255:0] write_value(input int beat,input int number);
    for(int k=0;k<32;k++) write_value[k*8+:8]=8'(k*19+beat*73+number*13);
  endfunction

  always_comb begin
    avm_readdatavalid=delayed_valid;
    avm_readdata=delayed_data;
    avm_readdataerror=delayed_error;
    if(instant_return) begin
      avm_readdatavalid=1;
      avm_readdata=line_data(avm_address,avm_byteenable);
      avm_readdataerror=inject_error;
    end
  end
  always @(negedge user_clk) begin
    cycles++;
    avm_waitrequest=!common_cold_reset_n || manual_stall ||
                    forced_stall>0 || cycles%7<4;
    if(forced_stall>0) forced_stall--;
  end
  always @(posedge user_clk) begin : memory_model
    logic [63:0] beat_address,mask;
    int group_beats;
    longint unsigned byte_base;
    delayed_valid<=0;
    if(!common_cold_reset_n) begin
      pending=0;
      delayed_error<=0;
    end else begin
      if(avm_readdatavalid) backend_returns++;
      if(pending) begin
        if(delay_left==0) begin
          delayed_valid<=1;
          delayed_data<=pending_data;
          delayed_error<=pending_error;
          pending=0;
        end else delay_left--;
      end
      if((avm_read || avm_write) && avm_waitrequest) stalls++;
      if((avm_read || avm_write) && !avm_waitrequest) begin
        if((avm_read && avm_write) || avm_burstcount!==1'b1)
          $fatal(1,"invalid backend direction/burst");
        byte_base=64'(avm_address)<<6;
        if(avm_address==core_address) begin
          if(!avm_read || avm_byteenable!==64'hffffffffffffffff)
            $fatal(1,"competing core command changed");
          core_commands++;
        end else begin
          if(!expected_active || accepted>=expected_beats)
            $fatal(1,"unexpected DMA backend command");
          beat_address=expected_base+64'(accepted*32);
          group_beats=(!beat_address[5] && accepted+1<expected_beats)?2:1;
          mask='0;
          for(int half=0;half<group_beats;half++)
            mask[(int'(beat_address[5])+half)*32+:32]=expected_write?write_masks[accepted+half]:expected_mask;
          if(avm_address!==beat_address[30:6] || avm_byteenable!==mask ||
             avm_write!==expected_write)
            $fatal(1,"coalesced DMA mapping mismatch: index=%0d group=%0d",accepted,group_beats);
          if(expected_write)
            for(int half=0;half<group_beats;half++)
              for(int k=0;k<32;k++)
                if(write_masks[accepted+half][k] &&
                   avm_writedata[((int'(beat_address[5])+half)*32+k)*8+:8]!==write_values[accepted+half][k*8+:8])
                  $fatal(1,"coalesced H2D lane/data changed");
          accepted+=group_beats;case_commands++;
          if(group_beats==2)pairs++;
          dma_commands++;
        end
        if(avm_write) begin
          for(int k=0;k<64;k++)
            if(avm_byteenable[k]) memory_bytes[byte_base+64'(k)]=avm_writedata[k*8+:8];
        end else begin
          if(pending || delayed_valid) $fatal(1,"backend read ownership overlap");
          if(!instant_return) begin
            pending_data=line_data(avm_address,avm_byteenable);
            pending_error=inject_error;
            pending=1;
            delay_left=delay_override>=0 ? delay_override : $urandom_range(max_response_delay,0);
          end
        end
      end
    end
  end
  always @(posedge pcie_clk) if(common_cold_reset_n) begin
    if(wr_dma_read_o && !wr_dma_wait_request_i) read_accepts++;
    if(rd_dma_write_o && !rd_dma_wait_request_i) write_accepts++;
    if(wr_dma_read_data_valid_i) begin
      if(!expected_active || expected_write) $fatal(1,"response without D2H ownership");
      dma_responses++;
    end
    if(fault && (!rd_dma_wait_request_i || !wr_dma_wait_request_i ||
                 wr_dma_read_data_valid_i)) $fatal(1,"fault did not quarantine PCIe interface");
  end
  assert property (@(posedge user_clk)
    disable iff(!common_cold_reset_n || !backend_reset_n || mux_fault)
    (avm_read || avm_write) && avm_waitrequest |=>
    $stable({avm_read,avm_write,avm_address,avm_writedata,avm_byteenable,avm_burstcount}))
    else $fatal(1,"backend command changed while stalled");

  task automatic check_core_return;
    if(core_readdataerror) $fatal(1,"competing core received error");
    for(int k=0;k<64;k++)
      if(core_readdata[k*8+:8]!==reference_byte((64'(core_address)<<6)+64'(k)))
        $fatal(1,"response routed to wrong owner/lane");
    core_responses++;
  endtask
  initial begin : competing_core
    bit returned;
    wait(run_core);
    while(!stop_core) begin
      @(negedge user_clk);
      core_read=1;
      do begin
        @(posedge user_clk);
        if(ddr_lock && core_waitrequest) overlaps++;
      end while(core_waitrequest);
      returned=core_readdatavalid;
      if(returned) check_core_return();
      @(negedge user_clk);
      core_read=0;
      if(!returned) begin
        do @(posedge user_clk); while(!core_readdatavalid);
        check_core_return();
      end
    end
    core_done=1;
  end

  task automatic cold_reset;
    @(negedge pcie_clk);
    common_cold_reset_n=0;
    rd_dma_write_o=0;wr_dma_read_o=0;
    app_nreset_status=1;backend_reset_n=1;memory_ready=1;memory_failed=0;quiesce=0;
    expected_active=0;manual_stall=0;forced_stall=0;inject_error=0;
    response_mode=1;delay_override=-1;
    repeat(4) @(negedge pcie_clk);
    common_cold_reset_n=1;
    // Reset/health synchronizer startup only; completion is never inferred here.
    repeat(12) @(negedge pcie_clk);
    if(fault || mux_fault || busy || owned_beats!=0)
      $fatal(1,"common cold reset did not start a new empty epoch");
  endtask

  task automatic read_case(input logic [63:0] raw_address,input int beats,
                           input logic [31:0] mask,input bit hold_header=0);
    int first_accept,first_response;
    @(negedge pcie_clk);
    if(busy || fault || mux_fault) $fatal(1,"read started without an empty live adapter");
    expected_active=1;expected_write=0;
    expected_base={raw_address[63:5],5'b0};
    expected_beats=beats;expected_mask=mask;accepted=0;case_commands=0;
    first_accept=read_accepts;first_response=dma_responses;
    response_mode=cases%3==0 ? 0 : 1;
    forced_stall=19;
    quiesce=hold_header;
    wr_dma_address_o=raw_address;wr_dma_burst_count_o=5'(beats);
    wr_dma_read_byte_enable_o=mask;wr_dma_read_o=1;
    if(hold_header) begin
      repeat(9) begin
        @(posedge pcie_clk);
        if(!wr_dma_wait_request_i || fault) $fatal(1,"quiesced header accepted/faulted");
        @(negedge pcie_clk);
      end
      quiesce=0;
    end
    do begin
      @(posedge pcie_clk);
      if(fault) $fatal(1,"legal D2H header rejected: %h %h",raw_address,mask);
    end while(wr_dma_wait_request_i);
    @(negedge pcie_clk);
    wr_dma_read_o=0;
    // Captured header/mask must survive these changes through CDC and stalls.
    wr_dma_address_o=~raw_address;wr_dma_burst_count_o=0;
    wr_dma_read_byte_enable_o=~mask;
    for(int i=0;i<beats;i++) begin
      do begin
        @(posedge pcie_clk);
        if(fault || mux_fault) $fatal(1,"legal D2H transfer faulted");
      end while(!wr_dma_read_data_valid_i);
      for(int k=0;k<32;k++)
        if(mask[k] && wr_dma_read_data_i[k*8+:8]!==reference_byte(expected_base+64'(i*32+k)))
          $fatal(1,"D2H response shifted or aliased: raw=%h beat=%0d byte=%0d",raw_address,i,k);
    end
    @(negedge pcie_clk);
    while(busy) @(negedge pcie_clk);
    if(accepted!=beats || case_commands!=(beats+int'(expected_base[5])+1)/2 || read_accepts-first_accept!=1 ||
       dma_responses-first_response!=beats || fault || mux_fault)
      $fatal(1,"D2H command/response count mismatch");
    expected_active=0;cases++;
  endtask

  task automatic write_case(input int lane,input int beats);
    int first_accept;
    @(negedge pcie_clk);
    if(busy || fault || mux_fault) $fatal(1,"write started without an empty live adapter");
    expected_active=1;expected_write=1;expected_base=64'h5000+64'(lane*32);
    expected_beats=beats;accepted=0;case_commands=0;first_accept=write_accepts;
    for(int i=0;i<beats;i++) begin
      write_masks[i]=32'ha5a55a5a ^ (32'hf<<((i%8)*4));
      if(beats==1 || i%4==0) write_masks[i]=0; // Preserve aligned zero-enable write behavior.
      write_values[i]=write_value(i,cases);
    end
    for(int i=0;i<beats;i++) begin
      rd_dma_address_o=i==0 ? expected_base : 64'hffffffffffffffff;
      rd_dma_burst_count_o=i==0 ? 5'(beats) : 5'b0;
      rd_dma_write_data_o=write_values[i];rd_dma_byte_enable_o=write_masks[i];
      rd_dma_write_o=1;
      do begin
        @(posedge pcie_clk);
        if(fault || mux_fault) $fatal(1,"legal H2D transfer faulted");
      end while(rd_dma_wait_request_i);
      for(int k=0;k<32;k++)
        if(write_masks[i][k]) reference_bytes[expected_base+64'(i*32+k)]=write_values[i][k*8+:8];
      @(negedge pcie_clk);
      rd_dma_write_o=0;
      if(i==0 && beats>1) quiesce=1; // Finish this accepted burst under quiesce.
      repeat(i%3) @(negedge pcie_clk);
    end
    rd_dma_write_data_o='x;rd_dma_byte_enable_o='x;
    while(busy) @(negedge pcie_clk);
    if(accepted!=beats || case_commands!=(beats+lane+1)/2 || write_accepts-first_accept!=beats || fault || mux_fault ||
       (beats>1 && !quiesced)) $fatal(1,"H2D ownership/drain mismatch");
    quiesce=0;expected_active=0;cases++;
  endtask

  task automatic reject_case(input bit is_write,input logic [63:0] raw_address,
                             input logic [4:0] beats,input logic [31:0] mask);
    int first_command,first_response;
    cold_reset();
    first_command=dma_commands;first_response=dma_responses;
    @(negedge pcie_clk);
    if(is_write) begin
      rd_dma_address_o=raw_address;rd_dma_burst_count_o=beats;
      rd_dma_byte_enable_o=mask;rd_dma_write_data_o='1;rd_dma_write_o=1;
    end else begin
      wr_dma_address_o=raw_address;wr_dma_burst_count_o=beats;
      wr_dma_read_byte_enable_o=mask;wr_dma_read_o=1;
    end
    @(posedge pcie_clk);
    if(is_write ? !rd_dma_wait_request_i : !wr_dma_wait_request_i)
      $fatal(1,"malformed command was accepted");
    @(negedge pcie_clk);
    if(!fault || fault_code!==4'd1 || fault_address!==raw_address || busy || owned_beats!=0)
      $fatal(1,"malformed header diagnostic mismatch: %h",raw_address);
    quiesce=1;
    repeat(7) begin
      @(posedge pcie_clk);
      if(!fault || !rd_dma_wait_request_i || !wr_dma_wait_request_i ||
         wr_dma_read_data_valid_i || quiesced || avm_read || avm_write)
        $fatal(1,"malformed header quarantine lost");
    end
    @(negedge pcie_clk);
    rd_dma_write_o=0;wr_dma_read_o=0;
    if(dma_commands!=first_command || dma_responses!=first_response)
      $fatal(1,"malformed command leaked to DDR");
    rejections++;
  endtask

  task automatic start_fault_read(input logic [63:0] raw_address,
                                  input logic [31:0] mask,input int fault_beats=1);
    @(negedge pcie_clk);
    expected_active=1;expected_write=0;expected_base={raw_address[63:5],5'b0};
    expected_beats=fault_beats;expected_mask=mask;accepted=0;case_commands=0;
    wr_dma_address_o=raw_address;wr_dma_burst_count_o=5'(fault_beats);
    wr_dma_read_byte_enable_o=mask;wr_dma_read_o=1;
    do begin
      @(posedge pcie_clk);
      if(fault || mux_fault) $fatal(1,"legal fault-injection head rejected");
    end while(wr_dma_wait_request_i);
    @(negedge pcie_clk);
    wr_dma_read_o=0;wr_dma_address_o=0;wr_dma_burst_count_o=0;
    wr_dma_read_byte_enable_o=0;
  endtask
  task automatic check_quarantine(input logic [63:0] original_address,input int code,input int fault_beats=1);
    if(!fault || (code!=0 && fault_code!==4'(code)) || fault_address!==original_address ||
       !busy || owned_beats!==5'(fault_beats) || !rd_dma_wait_request_i || !wr_dma_wait_request_i ||
       wr_dma_read_data_valid_i || quiesced)
      $fatal(1,"accepted raw-address ownership/diagnostic was not quarantined");
  endtask
  task automatic quarantine_tests;
    int first_command,first_response,first_return;
    // A real accepted read error must report the raw head, not its rounded base.
    cold_reset();
    inject_error=1;response_mode=1;delay_override=23;
    first_response=dma_responses;
    start_fault_read(64'h402c,32'hfffff000);
    wait(fault);
    @(negedge pcie_clk);
    check_quarantine(64'h402c,3);
    wait(!ddr_lock);
    if(accepted!=1 || dma_responses!=first_response) $fatal(1,"error returned payload/replayed");
    quarantine_cases++;

    // A paired command returning an error must expose neither half to HIP.
    for(int mode=0;mode<2;mode++) begin
      cold_reset();inject_error=1;response_mode=mode;delay_override=11;
      first_response=dma_responses;
      start_fault_read(64'h6000,32'ha5a50000,2);
      wait(fault);@(negedge pcie_clk);check_quarantine(64'h6000,3,2);
      wait(!ddr_lock);
      if(accepted!=2 || case_commands!=1 || dma_responses!=first_response)
        $fatal(1,"paired error leaked/replayed payload");
      quarantine_cases++;
    end
    // Link loss retains PCIe ownership; an already presented DDR read finishes.
    cold_reset();
    manual_stall=1;response_mode=1;delay_override=29;
    first_response=dma_responses;first_return=backend_returns;
    start_fault_read(64'h403c,32'hf0000000);
    wait(avm_read && avm_waitrequest);
    @(negedge pcie_clk);
    app_nreset_status=0;
    #1 app_nreset_status=1;
    wait(fault);
    @(negedge pcie_clk);
    check_quarantine(64'h403c,2);
    manual_stall=0;
    wait(backend_returns==first_return+1);
    wait(!ddr_lock);
    @(negedge pcie_clk);
    check_quarantine(64'h403c,2);
    if(accepted!=1 || dma_responses!=first_response) $fatal(1,"link-loss completion leaked/replayed");
    quarantine_cases++;

    // A backend reset pulse invalidates the epoch before a stalled read accepts.
    cold_reset();
    manual_stall=1;
    first_command=dma_commands;first_response=dma_responses;
    start_fault_read(64'h4014,32'hfff00000);
    wait(avm_read && avm_waitrequest);
    @(negedge pcie_clk);
    backend_reset_n=0;
    #1 backend_reset_n=1;
    wait(fault);
    @(negedge pcie_clk);
    check_quarantine(64'h4014,0);
    manual_stall=0;
    // Exercise recovered health qualification; it is not a command-drain rule.
    repeat(12) @(negedge pcie_clk);
    check_quarantine(64'h4014,0);
    if(!mux_fault || !ddr_lock || dma_commands!=first_command ||
       dma_responses!=first_response || avm_read || avm_write)
      $fatal(1,"backend epoch auto-rearmed or dropped retained ownership");
    quarantine_cases++;
    cold_reset();
    read_case(64'h4014,1,32'hfff00000);
  endtask

  initial begin : test
    logic [63:0] raw_address;
    int seed=1,discard;
    discard=$value$plusargs("SEED=%d",seed);discard=$urandom(seed);
    if($value$plusargs("DMA_MAX_RESPONSE_DELAY=%d",max_response_delay)) begin end
    if(max_response_delay<0) $fatal(1,"DMA_MAX_RESPONSE_DELAY must be nonnegative");
    cold_reset();
    run_core=1;
    // Every native DWORD head offset in both halves, including every legal
    // within-head DWORD length. Native descriptor segmentation has its own test.
    for(int lane=0;lane<2;lane++) begin
      for(int offset=0;offset<32;offset+=4) begin
        raw_address=64'h4000+64'(lane*32+offset);
        for(int bytes=4;bytes<=32-offset;bytes+=4)
          read_case(raw_address,1,interval_mask(offset,bytes),bytes==4);
        // The transport preserves byte-granular/sparse masks above the start.
        for(int bitno=offset;bitno<32;bitno++)
          read_case(raw_address,1,32'b1<<bitno);
        read_case(raw_address,1,(32'ha596c33c<<offset));
      end
      read_case(64'h4000+64'(lane*32),1,0);
      for(int n=1;n<=16;n++) begin
        read_case(64'h4000+64'(lane*32),n,32'h39fa50c3,n==16);
        write_case(lane,n);
        read_case(64'h5000+64'(lane*32),n,32'hffffffff);
      end
    end
    // The last aligned beat is valid even when raw_address + 32 exceeds 2 GiB.
    for(int offset=0;offset<32;offset+=4) begin
      read_case(64'h7fffffe0+64'(offset),1,32'hffffffff<<offset,1);
      read_case(64'h7fffffe0+64'(offset),1,32'h80000000);
    end
    read_case(64'h7ffffe00,16,32'hffffffff);
    stop_core=1;
    wait(core_done);
    if(core_commands==0 || core_commands!=core_responses || overlaps==0 || stalls==0)
      $fatal(1,"two-owner/stall coverage missing");
    for(int i=0;i<32768;i++)
      if(memory_byte(64'(i))!==reference_byte(64'(i))) $fatal(1,"32 KiB byte scoreboard mismatch at %0d",i);

    for(int lane=0;lane<2;lane++)
      for(int offset=4;offset<32;offset+=4) begin
        raw_address=64'h4000+64'(lane*32+offset);
        reject_case(0,raw_address,2,32'hffffffff<<offset);
        reject_case(0,raw_address,16,32'hffffffff<<offset);
        reject_case(0,raw_address,1,0);
        for(int lower=0;lower<offset;lower++)
          reject_case(0,raw_address,1,(32'hffffffff<<offset) | (32'b1<<lower));
        reject_case(1,raw_address,1,32'hffffffff<<offset);
      end
    for(int lane=0;lane<2;lane++)
      for(int offset=1;offset<32;offset++)
        if(offset%4!=0)
          reject_case(0,64'h4000+64'(lane*32+offset),1,32'hffffffff<<offset);
    for(int n=0;n<32;n++)
      if(n==0 || n>16) begin
        reject_case(0,64'h4000,5'(n),32'hffffffff);
        reject_case(1,64'h4000,5'(n),32'hffffffff);
      end
    reject_case(0,64'h7fffffe0,2,32'hffffffff);
    reject_case(0,64'h7ffffe20,16,32'hffffffff);
    reject_case(1,64'h7fffffe0,2,32'hffffffff);
    reject_case(0,64'h80000000,1,32'hffffffff);
    reject_case(0,64'h80000004,1,32'hfffffff0);
    reject_case(1,64'h80000000,1,32'hffffffff);
    reject_case(0,64'h100000000,1,32'hffffffff);
    reject_case(0,64'h8000000000000000,1,32'hffffffff);
    reject_case(0,64'hffffffffffffffe0,16,32'hffffffff);
    reject_case(0,64'hfffffffffffffffc,1,32'hf0000000);
    quarantine_tests();
    if(fault || mux_fault || busy) $fatal(1,"final cold-reset recovery failed");
    if(pairs==0) $fatal(1,"no paired commands exercised");
    $display("LINE_COALESCING_PASS cases=%0d rejected=%0d quarantine=%0d dma_commands=%0d dma_responses=%0d core=%0d stalls=%0d overlaps=%0d max_delay=%0d pairs=%0d",
             cases,rejections,quarantine_cases,dma_commands,dma_responses,core_commands,stalls,overlaps,max_response_delay,pairs);
    $finish;
  end
endmodule
