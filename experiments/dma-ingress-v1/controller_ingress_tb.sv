// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
// Actual write controller plus native descriptor FIFO/producer.
// The memory-return and metadata consumers are fixtures, not the packetizer.
// The exact application valid expression is supplied in ingress_valid.svh.
module controller_ingress_tb;
  logic clk=0, rstn=0;
  always #5 clk=~clk;
  logic cs=0, cswrite=0, csread=0;
  logic [7:0] csaddr=0; logic [31:0] csdata=0;
  wire cswait; wire [31:0] csreaddata;
  logic dtscs=0, dtswrite=0; logic [255:0] dtsdata=0;
  wire dtswait;
  wire ready;
  logic fetch_ack=0;
  wire valid, fetch_req; wire [159:0] data, fetch_data;
  wire [7:0] first_id;
  int fetch_count=0, data_count=0;
  bit held_tx=0, held_fetch=0;
  logic [159:0] held_data; logic [167:0] held_fetch_bus;
  altpcie_dynamic_control_write_v4 #(.READ_CONTROL(0),.DMA_WIDTH(256)) controller (
    .Clk_i(clk),.Rstn_i(rstn),.MsiInterface_i(82'b0),
    .DCSChipSelect_i(cs),.DCSWrite_i(cswrite),.DCSAddress_i(csaddr),.DCSWriteData_i(csdata),
    .DCSByteEnable_i(4'hf),.DCSRead_i(csread),.DCSReadData_o(csreaddata),.DCSWaitRequest_o(cswait),
    .DCMAddress_o(),.DCMWrite_o(),.DCMWriteData_o(),.DCMRead_o(),.DCMByteEnable_o(),
    .DCMWaitRequest_i(1'b1),.DCMReadData_i(32'b0),.DCMReadDataValid_i(1'b0),
    .DTSChipSelect_i(dtscs),.DTSWrite_i(dtswrite),.DTSBurstCount_i(5'd2),
    .DTSAddress_i(8'd0),.DTSWriteData_i(dtsdata),.DTSWaitRequest_o(dtswait),
    .DmaTxData_o(data),.DmaTxValid_o(valid),.DmaTxReady_i(ready),
    .DmaRxData_i(32'b0),.DmaRxValid_i(1'b0),
    .WrDescTxData_o(fetch_data),.WrDescTxReq_o(fetch_req),.WrDescTxAck_i(fetch_ack),
    .WrDescTxAck_o(),.WrDescTxReq_i(1'b0),.WrDescTxData_i(160'b0),
    .WrDescFirstId_i(8'b0),.WrDescFirstId_o(first_id)
  );
  wire AvWrDmaRxValid_i=valid;
  wire AvWrDmaRxReady_o=ready;
  `include "ingress_valid.svh"
  wire read_req;
  wire [63:0] address;
  wire [4:0] burst,complete_count;
  wire [2:0] metadata_count;
  logic waitrequest=1,returned=0;
  int native_cycles=0,native_enqueued=0,native_popped=0,native_commands=0,stalled=0;
  altpcieav_dma_wr_readmem_2 producer(
    .Clk_i(clk),.Srst_i(!rstn),
    .WrDmaRead_o(read_req),.WrDmaAddress_o(address),
    .WrDmaReadByteEnable_o(),.WrDmaBurstCount_o(burst),
    .WrDmaWaitRequest_i(waitrequest),.WrDmaReadDataValid_i(returned),
    .WrDmaReadData_i(256'b0),.WrDmaRxData_i(data),
    .WrDmaRxValid_i(native_valid),.WrDmaRxReady_o(ready),
    .RawBuffRelease_i(returned),.RawBuffReleaseSize_i(9'd1),
    .DataRamReadAddr_i(9'b0),.DataRamReadData_o(),
    .TLPGenDescFifoRdReq_i(metadata_count!=0),.TLPGenDescFifoDataq_o(),
    .TLPGenDescFifoCount_o(metadata_count),.TLPGenBuffLimit_o(),
    .DescDataCompleteFifoRdReq_i(complete_count!=0),
    .DescDataCompleteFifoCount_o(complete_count));
  always @(negedge clk) begin
    native_cycles++;
    waitrequest=!rstn || native_cycles%53<47;
  end
  always @(posedge clk) begin
    returned <= rstn && read_req && !waitrequest;
    if(rstn) begin
      if(valid && !ready) stalled++;
      if(producer.desc_fifo_wrreq) native_enqueued++;
      // Compare current-cycle accepts without depending on monitor scheduling.
      if(producer.desc_fifo_wrreq !== (valid && ready))
        $fatal(1,"CONTROLLER_NATIVE_EXTRA_ENQUEUE valid=%b ready=%b",valid,ready);
      if(producer.pop_desc_state) begin
        if(native_popped>=48 || producer.desc_head!==descriptor(native_popped))
          $fatal(1,"CONTROLLER_NATIVE_DESCRIPTOR_MISMATCH index=%0d",native_popped);
        native_popped++;
      end
      if(read_req && !waitrequest) begin
        if(burst!==5'd1 || address!==64'(32'h6000+native_commands*32))
          $fatal(1,"CONTROLLER_NATIVE_COMMAND_MISMATCH index=%0d",native_commands);
        native_commands++;
      end
    end
  end
  function automatic logic [159:0] descriptor(input int id);
    return {6'b0,8'(id),18'd8,64'(32'h4000+id*32),64'(32'h6000+id*32)};
  endfunction
  task automatic tick;
    @(posedge clk); @(negedge clk); #1;
  endtask
  task automatic csr(input logic [7:0] address,input logic [31:0] value);
    cs=1; cswrite=1; csaddr=address; csdata=value; #1;
    while(cswait) tick(); tick(); cs=0; cswrite=0;
  endtask
  task automatic fetch_close;
    wait(fetch_req); fetch_ack=1; tick(); fetch_ack=0;
  endtask
  task automatic copy_descriptor(input int id);
    dtscs=1; dtswrite=1; dtsdata={96'b0,descriptor(id)}; #1;
    while(dtswait) tick(); tick(); dtscs=0; dtswrite=0;
  endtask
  always @(posedge clk) if(rstn) begin
    if(held_tx && (!valid || data!==held_data)) $fatal(1,"write DATA TX lost held descriptor");
    held_tx=valid&&!ready; if(held_tx) held_data=data;
    if(held_fetch && (!fetch_req || {fetch_data,first_id}!==held_fetch_bus))
      $fatal(1,"write-fetch snapshot changed before ACK");
    held_fetch=fetch_req&&!fetch_ack; if(held_fetch) held_fetch_bus={fetch_data,first_id};
    if(fetch_req && fetch_ack) begin
      if(fetch_count>=2 || fetch_data[153:146]!==8'(192+fetch_count) ||
         fetch_data[145:128]!=16 || fetch_data[63:0]!==64'(32'h8200+fetch_count*64) ||
         first_id!==8'(fetch_count*2)) $fatal(1,"write fetch accounting advanced from live controls or stall cycles");
      fetch_count++;
    end
    if(valid && ready) begin
      if(data_count>=48 || data!==descriptor(data_count)) $fatal(1,"write FIFO data loss/order failure");
      data_count++;
    end
  end
  initial begin
    repeat(4) tick(); rstn=1; tick();
    csr(8'h00,32'h8000); csr(8'h04,0); csr(8'h0c,0); csr(8'h08,32'h1000); csr(8'h10,1);
    wait(fetch_req); repeat(9) tick();
    if(fetch_count || fetch_data[153:146]!=192) $fatal(1,"fetch counter advanced without ACK");
    csr(8'h10,3); repeat(5) tick();
    // A configuration write stalls while both old and queued snapshots exist.
    fork
      csr(8'h00,32'h9000);
      begin
        repeat(7) tick(); if(!cswait) $fatal(1,"base changed during held fetch");
        fetch_close(); wait(fetch_req); repeat(7) tick(); fetch_close();
      end
    join
    if(fetch_count!=2) $fatal(1,"queued write doorbell lost");
    cs=1; csread=1; csaddr=0; #1; while(cswait) tick();
    if(csreaddata!==32'h9000) $fatal(1,"stalled configuration write never took effect");
    tick(); cs=0; csread=0;
    for(int i=0;i<48;i++) copy_descriptor(i);
    while(data_count!=48 || native_popped!=48 || native_commands!=48 ||
          metadata_count!=0 || complete_count!=0 || returned) tick();
    repeat(7) tick();
    if(valid || fetch_req || fetch_count!=2 || native_enqueued!=48 || stalled==0)
      $fatal(1,"CONTROLLER_NATIVE_FINAL_COUNTS");
    $display("CONTROLLER_NATIVE_PASS descriptors=48 enqueued=%0d popped=%0d commands=%0d stalled=%0d",native_enqueued,native_popped,native_commands,stalled);
    $finish;
  end
endmodule
