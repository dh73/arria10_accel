// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
// Requires the source-checked ORIGINAL licensed READ_CONTROL=0 derivative.
// This tests the necessary TX/snapshot/FIFO changes. The legacy status region
// is preserved by the builder; this bench does not invent its unpublished ABI.
module dma_write_controller_fetch_v4_tb;
  logic clk=0, rstn=0;
  always #5 clk=~clk;
  logic cs=0, cswrite=0, csread=0;
  logic [7:0] csaddr=0; logic [31:0] csdata=0;
  wire cswait; wire [31:0] csreaddata;
  logic dtscs=0, dtswrite=0; logic [255:0] dtsdata=0;
  wire dtswait;
  logic ready=1, fetch_ack=0;
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
      if(data_count>=2 || data!==descriptor(data_count)) $fatal(1,"write FIFO data loss/order failure");
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
    copy_descriptor(0); wait(valid); ready=0;
    repeat(7) tick(); copy_descriptor(1); repeat(7) tick();
    if(data_count) $fatal(1,"DATA TX accepted with ready low");
    ready=1; wait(data_count==2); repeat(7) tick();
    if(valid || fetch_req || fetch_count!=2) $fatal(1,"write controller replayed work");
    $display("PASS actual_write_controller_fetch_v4 two held fetch snapshots, queued doorbell, DCS config stall, two retained DATA TX descriptors");
    $finish;
  end
endmodule
