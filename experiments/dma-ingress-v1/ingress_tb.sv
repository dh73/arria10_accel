`timescale 1ns/1ps
// Actual native producer/FIFO; host offers remain valid until accepted.
// Only the application port expression is extracted into ingress_valid.svh.
module ingress_tb;
  logic clk=0, reset=1;
  always #5 clk=~clk;
  logic AvWrDmaRxValid_i=0;
  wire AvWrDmaRxReady_o;
  logic [159:0] data=0;
  wire read_req;
  wire [63:0] address;
  wire [4:0] burst, complete_count;
  wire [2:0] metadata_count;
  logic waitrequest=1, returned=0;
  int cycles=0, admitted=0, popped=0, stalled=0, enqueued=0, commands=0;
  int epoch=0;
  logic [159:0] expected[$];
  `include "ingress_valid.svh"
  altpcieav_dma_wr_readmem_2 dut(
    .Clk_i(clk),.Srst_i(reset),
    .WrDmaRead_o(read_req),.WrDmaAddress_o(address),
    .WrDmaReadByteEnable_o(),.WrDmaBurstCount_o(burst),
    .WrDmaWaitRequest_i(waitrequest),.WrDmaReadDataValid_i(returned),
    .WrDmaReadData_i(256'b0),.WrDmaRxData_i(data),
    .WrDmaRxValid_i(native_valid),.WrDmaRxReady_o(AvWrDmaRxReady_o),
    .RawBuffRelease_i(returned),.RawBuffReleaseSize_i(9'd1),
    .DataRamReadAddr_i(9'b0),.DataRamReadData_o(),
    .TLPGenDescFifoRdReq_i(metadata_count!=0),
    .TLPGenDescFifoDataq_o(),.TLPGenDescFifoCount_o(metadata_count),
    .TLPGenBuffLimit_o(),.DescDataCompleteFifoRdReq_i(complete_count!=0),
    .DescDataCompleteFifoCount_o(complete_count));
  always @(negedge clk) begin
    cycles++;
    waitrequest=reset || cycles%31<24;
  end
  always @(posedge clk) begin
    returned <= !reset && read_req && !waitrequest;
    if(!reset) begin
      if(AvWrDmaRxValid_i && !AvWrDmaRxReady_o) stalled++;
      if(AvWrDmaRxValid_i && AvWrDmaRxReady_o) begin
        expected.push_back(data);admitted++;
      end
      if(dut.desc_fifo_wrreq) enqueued++;
      if(enqueued!=admitted)
        $fatal(1,"INGRESS_EXTRA_ENQUEUE admitted=%0d enqueued=%0d",admitted,enqueued);
      if(dut.pop_desc_state) begin
        if(expected.size()==0 || dut.desc_head!==expected[0])
          $fatal(1,"INGRESS_DESCRIPTOR_MISMATCH popped=%0d",popped);
        void'(expected.pop_front());popped++;
      end
      if(read_req && !waitrequest) begin
        if(burst!==5'd1) $fatal(1,"INGRESS_UNEXPECTED_COMMAND");
        commands++;
      end
    end
  end
  initial begin
    for(epoch=0;epoch<4;epoch++) begin
      reset=1;AvWrDmaRxValid_i=0;
      repeat(4) @(negedge clk);
      reset=0;
      for(int i=0;i<48;i++) begin
        @(negedge clk);
        data={6'b0,8'(epoch*48+i),18'd8,64'(64'h10000+i*32),64'(64'h2000+i*32)};
        AvWrDmaRxValid_i=1;
        do @(posedge clk); while(AvWrDmaRxReady_o!==1'b1);
        @(negedge clk);AvWrDmaRxValid_i=0;
      end
      while(popped!=(epoch+1)*48 || commands!=(epoch+1)*48 ||
            metadata_count!=0 || complete_count!=0 || returned)
        @(negedge clk);
      if(expected.size()!=0) $fatal(1,"INGRESS_UNDRAINED");
      @(negedge clk);
    end
    if(stalled==0 || admitted!=192 || enqueued!=192 || popped!=192)
      $fatal(1,"INGRESS_COVERAGE_MISSING");
    $display("INGRESS_NATIVE_PASS admitted=%0d enqueued=%0d popped=%0d commands=%0d stalled=%0d epochs=4",admitted,enqueued,popped,commands,stalled);
    $finish;
  end
endmodule
