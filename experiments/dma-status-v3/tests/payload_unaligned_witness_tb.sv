`timescale 1ns/1ps
module payload_unaligned_witness_tb;
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
  dma_payload_mask_candidate dut(.*);
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
    avm_readdatavalid<=0;
    if(common_cold_reset_n && avm_write) $fatal(1,"unexpected write");
    if(avm_read && avm_waitrequest) stalls++;
    if(avm_read && !avm_waitrequest) begin
      addr=expected_base+64'(accepted*32);
      mask={32'b0,expected_mask} << (addr[5]*32);
      if(accepted>=expected_beats || avm_address!==addr[30:6] ||
         avm_byteenable!==mask || avm_burstcount!==1'b1)
        $fatal(1,"command mask/address mismatch beat=%0d got=%h expected=%h",accepted,avm_byteenable,mask);
      accepted++;commands++;
      avm_readdata<={data_for({addr[63:6],6'b100000}),data_for({addr[63:6],6'b000000})};
      avm_readdatavalid<=1;
    end
  end
  task automatic read_case(input int lane,input int beats,input logic [31:0] mask);
    @(negedge pcie_clk);
    expected_base=64'h1000+64'(lane*32);
    expected_beats=beats;expected_mask=mask;accepted=0;
    wr_dma_address_o=expected_base;wr_dma_burst_count_o=5'(beats);
    wr_dma_read_byte_enable_o=mask;wr_dma_read_o=1;
    do @(posedge pcie_clk); while(wr_dma_wait_request_i);
    @(negedge pcie_clk);
    wr_dma_read_o=0;wr_dma_read_byte_enable_o=~mask;
    wr_dma_address_o='1;wr_dma_burst_count_o=0;
    for(int i=0;i<beats;i++) begin
      do @(posedge pcie_clk); while(!wr_dma_read_data_valid_i);
      if(wr_dma_read_data_i!==data_for(expected_base+64'(i*32)))
        $fatal(1,"return lane mismatch");
      responses++;
    end
    @(negedge pcie_clk);
    if(accepted!=beats || fault) $fatal(1,"count/fault mismatch");
    cases++;
  endtask
  initial begin
    for(int lane=0;lane<2;lane++) begin
      for(int offset=4;offset<32;offset+=4) begin
        @(negedge pcie_clk);common_cold_reset_n=0;wr_dma_read_o=0;
        repeat(4) @(negedge pcie_clk);
        common_cold_reset_n=1;
        repeat(12) @(negedge pcie_clk);
        wr_dma_address_o=64'h1000+64'(lane*32+offset);
        wr_dma_burst_count_o=1;
        wr_dma_read_byte_enable_o=32'hffffffff<<offset;
        wr_dma_read_o=1;
        @(posedge pcie_clk);
        if(!wr_dma_wait_request_i) $fatal(1,"unexpected acceptance");
        @(negedge pcie_clk);
        if(!fault || fault_code!=1 || fault_address!==wr_dma_address_o ||
           avm_read || wr_dma_read_data_valid_i)
          $fatal(1,"unaligned rejection witness missing");
        $display("REJECTED_NATIVE_HEAD address=%h mask=%h",wr_dma_address_o,wr_dma_read_byte_enable_o);
        cases++;
      end
    end
    if(commands!=0 || cases!=14) $fatal(1,"witness coverage missing");
    $display("UNALIGNED_REJECTION_WITNESS_PASS cases=%0d backend_commands=%0d",cases,commands);
    $finish;
  end
endmodule
