`timescale 1ns/1ps
module memory_path_tb;
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
  wire busy,quiesced,fault,ddr_lock,avm_read,avm_write;
  wire [3:0] fault_code;
  wire [63:0] fault_address,avm_byteenable;
  wire [4:0] owned_beats;
  wire [24:0] avm_address;
  wire [511:0] avm_writedata;
  wire [0:0] avm_burstcount;
  logic avm_waitrequest=1,avm_readdatavalid=0,avm_readdataerror=0;
  logic [511:0] avm_readdata=0;
  logic [24:0] core_address=25'h100;
  logic core_read=0,core_write=0;
  logic [511:0] core_writedata=0;
  logic [63:0] core_byteenable='1;
  wire core_waitrequest,core_readdatavalid,core_readdataerror,mux_fault;
  wire [511:0] core_readdata;
  dma_memory_path_candidate dut(.*);
  logic [7:0] memory_bytes[0:32767],reference_bytes[0:32767];
  logic [31:0] write_masks[0:15];
  logic [255:0] write_values[0:15];
  bit expected_write=0,stop_core=0,core_done=0;
  int core_commands=0,core_responses=0,overlaps=0;
  int delay_left=0;
  bit pending=0;
  logic [511:0] pending_data;

  int cycles=0,commands=0,responses=0,cases=0,stalls=0;
  int expected_beats,accepted;
  logic [63:0] expected_base;
  logic [31:0] expected_mask;
  function automatic [255:0] data_for(input logic [63:0] addr);
    for(int i=0;i<32;i++) data_for[i*8+:8]=8'(addr+i);
  endfunction
  always @(negedge user_clk) begin
    cycles=cycles+1;
    avm_waitrequest=(cycles%5<3);
  end
  always @(posedge user_clk) begin : memory
    logic [63:0] addr,mask;
    int byte_base;
    avm_readdatavalid<=0;
    if(pending) begin
      if(delay_left==0) begin
        avm_readdatavalid<=1;avm_readdata<=pending_data;pending=0;
      end else delay_left--;
    end
    if((avm_read || avm_write) && avm_waitrequest) stalls++;
    if((avm_read || avm_write) && !avm_waitrequest) begin
      if(avm_address>=512 || (avm_read && avm_write) || avm_burstcount!==1'b1)
        $fatal(1,"backend command invalid");
      byte_base=int'(avm_address)*64;
      if(avm_address==core_address) begin
        if(!avm_read || avm_byteenable!==64'hffffffffffffffff)
          $fatal(1,"core command mismatch");
        core_commands++;
      end else begin
        addr=expected_base+64'(accepted*32);
        mask={32'b0,(expected_write ? write_masks[accepted] : expected_mask)} << (addr[5]*32);
        if(accepted>=expected_beats || avm_address!==addr[30:6] ||
           avm_byteenable!==mask || avm_write!==expected_write)
          $fatal(1,"DMA command mask/address/direction mismatch");
        if(expected_write)
          for(int k=0;k<32;k++)
            if(write_masks[accepted][k] &&
               avm_writedata[(int'(addr[5])*32+k)*8+:8]!==write_values[accepted][k*8+:8])
              $fatal(1,"write data mismatch");
        accepted++;commands++;
      end
      if(avm_write) begin
        for(int k=0;k<64;k++)
          if(avm_byteenable[k]) memory_bytes[byte_base+k]=avm_writedata[k*8+:8];
      end else begin
        if(pending) $fatal(1,"overlapping memory response");
        for(int k=0;k<64;k++)
          pending_data[k*8+:8]=avm_byteenable[k] ? memory_bytes[byte_base+k] : 8'hxx;
        pending=1;delay_left=cycles%4;
      end
    end
  end
  initial begin : competing_core
    wait(common_cold_reset_n);
    repeat(12) @(negedge user_clk);
    while(!stop_core) begin
      @(negedge user_clk);core_read=1;
      do begin
        @(posedge user_clk);
        if(ddr_lock && core_waitrequest) overlaps++;
      end while(core_waitrequest);
      @(negedge user_clk);core_read=0;
      do @(posedge user_clk); while(!core_readdatavalid);
      if(core_readdataerror) $fatal(1,"core error");
      for(int k=0;k<64;k++)
        if(core_readdata[k*8+:8]!==reference_bytes[int'(core_address)*64+k])
          $fatal(1,"core response routing mismatch");
      core_responses++;
    end
    core_done=1;
  end
  task automatic write_case(input int lane,input int beats);
    @(negedge pcie_clk);
    expected_base=64'h1000+64'(lane*32);
    expected_beats=beats;expected_write=1;accepted=0;
    for(int i=0;i<beats;i++) begin
      write_masks[i]=32'ha5a55a5a ^ (32'hf << (i%8)*4);
      write_values[i]=data_for(64'(i*73+cases*13));
      rd_dma_address_o=i==0 ? expected_base : 64'hffffffffffffffff;
      rd_dma_burst_count_o=i==0 ? 5'(beats) : 5'b0;
      rd_dma_write_data_o=write_values[i];rd_dma_byte_enable_o=write_masks[i];
      rd_dma_write_o=1;
      do @(posedge pcie_clk); while(rd_dma_wait_request_i);
      for(int k=0;k<32;k++)
        if(write_masks[i][k]) reference_bytes[int'(expected_base)+i*32+k]=write_values[i][k*8+:8];
      @(negedge pcie_clk);rd_dma_write_o=0;
      repeat(i%3) @(negedge pcie_clk);
    end
    rd_dma_write_data_o='x;rd_dma_byte_enable_o='x;
    while(busy) @(negedge pcie_clk);
    if(accepted!=beats || fault || mux_fault) $fatal(1,"write count/fault mismatch");
    cases++;
  endtask
  task automatic read_case(input int lane,input int beats,input logic [31:0] mask);
    @(negedge pcie_clk);
    expected_base=64'h1000+64'(lane*32);
    expected_beats=beats;expected_mask=mask;expected_write=0;accepted=0;
    wr_dma_address_o=expected_base;wr_dma_burst_count_o=5'(beats);
    wr_dma_read_byte_enable_o=mask;wr_dma_read_o=1;
    do @(posedge pcie_clk); while(wr_dma_wait_request_i);
    @(negedge pcie_clk);
    wr_dma_read_o=0;wr_dma_read_byte_enable_o=~mask;
    wr_dma_address_o='1;wr_dma_burst_count_o=0;
    for(int i=0;i<beats;i++) begin
      do @(posedge pcie_clk); while(!wr_dma_read_data_valid_i);
      for(int k=0;k<32;k++)
        if(mask[k] && wr_dma_read_data_i[k*8+:8]!==reference_bytes[int'(expected_base)+i*32+k])
          $fatal(1,"return lane/data mismatch");
      responses++;
    end
    @(negedge pcie_clk);
    if(accepted!=beats || fault) $fatal(1,"count/fault mismatch");
    cases++;
  endtask
  initial begin
    for(int i=0;i<32768;i++) begin memory_bytes[i]=8'(i);reference_bytes[i]=8'(i);end
    repeat(4) @(negedge pcie_clk);
    common_cold_reset_n=1;
    repeat(12) @(negedge pcie_clk);
    for(int lane=0;lane<2;lane++) begin
      for(int bitno=0;bitno<32;bitno++) read_case(lane,1,32'b1<<bitno);
      for(int n=1;n<8;n++) begin
        read_case(lane,1,32'hffffffff>>(32-n*4));
        read_case(lane,1,32'hffffffff<<(32-n*4));
      end
      for(int n=1;n<=16;n++) begin
        write_case(lane,n);
        read_case(lane,n,32'hffffffff);
      end
    end
    stop_core=1;wait(core_done);
    if(commands!=responses+272 || stalls==0 || overlaps==0 ||
       core_commands!=core_responses || core_commands==0 || fault || mux_fault)
      $fatal(1,"coverage/count/fault mismatch");
    for(int i=0;i<32768;i++)
      if(memory_bytes[i]!==reference_bytes[i]) $fatal(1,"memory corruption byte %0d",i);
    $display("MEMORY_PATH_PASS cases=%0d commands=%0d responses=%0d stalls=%0d core=%0d overlaps=%0d",cases,commands,responses,stalls,core_commands,overlaps);
    $finish;
  end
endmodule
