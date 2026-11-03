`timescale 1ns/1ps
// Actual producer count pipeline, with white-box operands. Descriptor ingress,
// payload traffic, FIFO retirement and CDC are outside this fixture's scope.
module readmem_count_tb;
  logic clk=0, reset=1;
  always #5 clk=~clk;
  logic [17:0] length_dw=0;
  logic [63:0] source_address=0;
  int checked=0;
  altpcieav_dma_wr_readmem_2 dut (
    .Clk_i(clk), .Srst_i(reset),
    .WrDmaWaitRequest_i(1'b1), .WrDmaReadDataValid_i(1'b0),
    .WrDmaReadData_i(256'b0), .WrDmaRxData_i(160'b0),
    .WrDmaRxValid_i(1'b0), .RawBuffRelease_i(1'b0),
    .RawBuffReleaseSize_i(9'b0), .DataRamReadAddr_i(9'b0),
    .TLPGenDescFifoRdReq_i(1'b0), .DescDataCompleteFifoRdReq_i(1'b0)
  );

  task automatic check_count(input int length, input int offset,
                             input bit expect_original_overflow);
    int expected;
    @(negedge clk);
    length_dw=18'(length);
    source_address=64'(4*offset);
    expected=(length+offset+7)/8;
    // Both real pipeline registers must have sampled the selected operands.
    repeat(2) @(posedge clk);
    #1;
    if(expect_original_overflow) begin
      if(expected!=32768 || dut.total_desc_bcnt!==16'b0)
        $fatal(1,"original overflow witness changed: actual=%0d expected=%0d",
               dut.total_desc_bcnt,expected);
    end else if(dut.total_desc_bcnt!==16'(expected))
      $fatal(1,"count length=%0d offset=%0d actual=%0d expected=%0d",
             length,offset,dut.total_desc_bcnt,expected);
    checked++;
  endtask

  initial begin
    repeat(4) @(negedge clk);
    reset=0;
    force dut.desc_dw_reg=length_dw;
    force dut.cur_src_addr_reg=source_address;
    if($test$plusargs("EXPECT_ORIGINAL_OVERFLOW")) begin
      check_count(262143,1,1);
      $display("READMEM_ORIGINAL_OVERFLOW_CONFIRMED checked=%0d",checked);
    end else begin
      for(int n=1;n<=262143;n++)
        for(int offset=0;offset<8;offset++) check_count(n,offset,0);
      if(checked!=2097144) $fatal(1,"incomplete arithmetic domain");
      $display("READMEM_COUNT_PIPELINE_PASS checked=%0d",checked);
    end
    release dut.desc_dw_reg;
    release dut.cur_src_addr_reg;
    $finish;
  end
endmodule
