`timescale 1ns/1ps
module read_dma_retirement_matrix_tb;
  logic clk=0,rstn=0,desc_valid=0,stall=1;
  logic [159:0] desc=0;
  wire ready,wr,rx_pop,tx_push,arb,tag_pop,status_valid;
  wire [63:0] addr;
  wire [255:0] data;
  wire [31:0] be,status_data,control_status;
  wire [4:0] burst;
  wire [259:0] tx;
  logic [265:0] packets[10];
  int offered=0,consumed=0,requests=0,beats=0,in_burst=0,statuses=0;
  bit premature=0, allow_writes=0;
  bit [7:0] seen=0;
  int mode=0, cycles=0;
  always @(posedge clk) cycles++;
  always @(negedge clk) stall=!allow_writes || ((mode==2 || mode==5) && cycles%7<3);
  logic [7:0] tags[2];
  wire [265:0] rx = (consumed<offered)?packets[consumed]:266'b0;
  wire [3:0] rx_count=(consumed<offered)?4'd1:4'd0;
  always #5 clk=~clk;
  altpcieav_dma_rd #(.DMA_WIDTH(256),.DMA_BE_WIDTH(32),
    .RDDMA_AVL_ADDR_WIDTH(64),.DEVICE_FAMILY("Arria 10")) dut (
    .Clk_i(clk),.Rstn_i(rstn),.RdDmaWrite_o(wr),.RdDmaAddress_o(addr),
    .RdDmaWriteData_o(data),.RdDmaBurstCount_o(burst),.RdDmaWriteEnable_o(be),
    .RdDmaWaitRequest_i(stall),.RdDmaRxData_i(desc),.RdDmaRxValid_i(desc_valid),
    .RdDmaRxReady_o(ready),.RdDmaTxData_o(status_data),.RdDmaTxValid_o(status_valid),
    .RxFifoRdReq_o(rx_pop),.RxFifoDataq_i(rx),.RxFifoCount_i(rx_count),
    .PreDecodeTagRdReq_o(tag_pop),.PreDecodeTag_i(rx[79:72]),.PreDecodeTagCount_i(rx_count),
    .TxFifoWrReq_o(tx_push),.TxFifoData_o(tx),.TxFifoCount_i(4'b0),
    .RdDMACntrlLoad_i(1'b0),.RdDMACntrlData_i(32'b0),.RdDMAStatus_o(control_status),
    .RdDMmaArbReq_o(arb),.RdDMmaArbGranted_i(arb),.BusDev_i(13'h100),
    .DevCsr_i(32'b0),.MasterEnable_i(1'b1),.ko_cpl_spc_header(8'hff),
    .ko_cpl_spc_data(12'hfff));
  always @(posedge clk) if(rstn) begin
    if(tx_push) begin
      if(requests>=2 || tx[9:0]!==10'd32 || tx[95:64]!==32'(32'h1000+128*requests))
        $fatal(1,"unexpected memory read request %h",tx);
      tags[requests]=tx[47:40]; requests++;
    end
    if(rx_pop) begin
      if(consumed>=offered) $fatal(1,"RX FIFO underflow");
      consumed<=consumed+1;
    end
    if(wr && !stall) begin
      if($isunknown({addr,burst,be,data}) || burst!=4 || be!==32'hffffffff)
        $fatal(1,"invalid Avalon beat address=%h burst=%d be=%h",addr,burst,be);
      if(addr<64'h2000 || addr>64'h2080 || addr[6:0]!=0)
        $fatal(1,"wrong payload burst address");
      if(seen[(addr-64'h2000)/32+in_burst]) $fatal(1,"duplicate payload beat");
      seen[(addr-64'h2000)/32+in_burst]=1;
      for(int d=0;d<8;d++)
        if(data[32*d+:32] !== 32'(32'hcafe0000+(addr-64'h2000)/4+8*in_burst+d))
          $fatal(1,"wrong payload beat=%0d lane=%0d value=%h",beats,d,data[32*d+:32]);
      beats++; in_burst=(in_burst+1)%4;
    end
    if(status_valid) begin
      statuses++;
      if(status_data!==32'h00000107) $fatal(1,"unexpected descriptor status %h",status_data);
      $display("STATUS descriptor=7 accepted_beats=%0d required_beats=8",beats);
      if(beats!=8) premature=1;
    end
  end
  initial begin
    if(!$value$plusargs("MODE=%d",mode)) mode=0;
    if(mode<0 || mode>5) $fatal(1,"invalid mode");
    repeat(5) @(negedge clk); rstn=1;
    wait(ready); @(negedge clk);
    desc[63:0]=64'h1000; desc[127:64]=64'h2000;
    desc[145:128]=18'd64; desc[153:146]=8'd7; desc_valid=1;
    @(negedge clk); desc_valid=0;
    wait(requests==2); @(negedge clk);
    // Two complete, aligned 128-byte CplDs, each answering one actual MRd.
    // Header occupies four DW in the 256-bit HIP layout (one padding DW).
    for(int t=0;t<2;t++) begin
      automatic int request_index=(mode>=4)?1-t:t;
      for(int p=0;p<5;p++) packets[t*5+p]=0;
      packets[t*5][31:0]=32'h4a000020;
      packets[t*5][63:32]=32'h00000080;
      packets[t*5][95:64]={16'h0800,tags[request_index],8'h00};
      packets[t*5][256]=1;
      for(int d=0;d<32;d++) begin
        automatic int pos=d+4;
        packets[t*5+pos/8][(pos%8)*32+:32]=32'(32'hcafe0000+request_index*32+d);
      end
      packets[t*5+4][257]=1;
      packets[t*5+4][259:258]=2'b10;
    end
    allow_writes=(mode!=0);
    offered=(mode==3)?5:10;
    if(mode==3) begin
      wait(beats==4); repeat(4) @(negedge clk); offered=10;
    end
    wait(consumed==10);
    if(mode==0) begin
      repeat(12) @(negedge clk); allow_writes=1;
    end
    wait(beats==8 && statuses==1);
    repeat(4) @(negedge clk);
    if(seen!==8'hff || statuses!=1) $fatal(1,"missing payload or duplicate status");
    if(premature) $fatal(1,"descriptor completed before all payload writes accepted");
    $display("PASS read DMA matrix mode=%0d beats=8 statuses=1",mode);
    $finish;
  end
endmodule
