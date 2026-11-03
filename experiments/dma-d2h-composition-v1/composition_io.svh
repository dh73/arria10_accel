// SPDX-License-Identifier: BSD-3-Clause
// Owned closed-loop wiring. Fetch ACK and DTS model only the committed-table
// copier boundary. No H2D fetch-return fabric or PCIe visibility is modeled.
logic cs=0,cswrite=0,csread=0;
logic [7:0] csaddr=0;
logic [31:0] csdata=0;
wire cswait;
wire [31:0] csreaddata;
logic dtscs=0,dtswrite=0;
logic [255:0] dtsdata=0;
wire dtswait;
wire [159:0] controller_data,fetch_data;
wire controller_valid,fetch_req;
wire controller_ready=rx_ready;
logic fetch_ack=0;
wire [7:0] first_id;
logic [81:0] msi_interface=0;
wire [63:0] dcm_address;
wire dcm_write,dcm_read;
wire [31:0] dcm_data;
wire [3:0] dcm_enable;
logic dcm_wait=1,host_hold=1,inject_failure=0;
wire retirement_fault,retirement_busy;
wire [31:0] retirement_fault_data;
wire [7:0] retirement_expected_id;
// Directed corruption downstream of the real packetizer, not a claim that
// its native implementation emits a failure word with this ID.
wire [31:0] controller_status = inject_failure ? 32'h0000007d : status_data;
assign rx_data=controller_data;
// The actual producer FIFO writes on VALID alone: pulse only on acceptance.
assign rx_valid=controller_valid && controller_ready;
altpcie_dynamic_control_write_d2h_v1 #(.READ_CONTROL(0),.DMA_WIDTH(256)) controller (
  .Clk_i(pcie_clk),.Rstn_i(common_cold_reset_n),.MsiInterface_i(msi_interface),
  .DCSChipSelect_i(cs),.DCSWrite_i(cswrite),.DCSAddress_i(csaddr),
  .DCSWriteData_i(csdata),.DCSByteEnable_i(4'hf),.DCSRead_i(csread),
  .DCSReadData_o(csreaddata),.DCSWaitRequest_o(cswait),
  .DCMAddress_o(dcm_address),.DCMWrite_o(dcm_write),.DCMWriteData_o(dcm_data),
  .DCMRead_o(dcm_read),.DCMByteEnable_o(dcm_enable),.DCMWaitRequest_i(dcm_wait),
  .DCMReadData_i(32'b0),.DCMReadDataValid_i(1'b0),
  .DTSChipSelect_i(dtscs),.DTSWrite_i(dtswrite),.DTSBurstCount_i(5'd1),
  .DTSAddress_i(8'd0),.DTSWriteData_i(dtsdata),.DTSWaitRequest_o(dtswait),
  .DmaTxData_o(controller_data),.DmaTxValid_o(controller_valid),.DmaTxReady_i(controller_ready),
  .DmaRxData_i(controller_status),.DmaRxValid_i(status_valid),
  .WrDescTxData_o(fetch_data),.WrDescTxReq_o(fetch_req),.WrDescTxAck_i(fetch_ack),
  .WrDescTxAck_o(),.WrDescTxReq_i(1'b0),.WrDescTxData_i(160'b0),
  .WrDescFirstId_i(8'b0),.WrDescFirstId_o(first_id),
  .RetireFault_o(retirement_fault),.RetireFaultData_o(retirement_fault_data),
  .RetireExpectedId_o(retirement_expected_id),.RetireBusy_o(retirement_busy));

// Real source-pinned FIFO; the dynamic queues below are independent oracles.
wire [5:0] tx_used;
wire [259:0] tx_front;
wire tx_pop=sink_pop && tx_used!=0;
altpcie_fifo #(.FIFO_DEPTH(32),.DATA_WIDTH(260)) packet_output_fifo (
  .clk(pcie_clk),.rstn(common_cold_reset_n),.srst(1'b0),
  .wrreq(tx_write),.rdreq(tx_pop),.data(tx_data),.q(tx_front),.fifo_count(tx_used));

typedef struct packed {
  logic [63:0] address;
  logic [31:0] data;
  int unsigned descriptor_index;
  bit interrupt_write;
} host_event_t;
host_event_t host_expected[$];
logic [159:0] ingress_expected[$];
logic [63:0] expected_header=0;
logic [31:0] expected_control=0;
logic [127:0] expected_endpoints=0;
int accepted_descriptors=0,dts_accepted=0,host_accepted=0,host_expected_count=0;
int status_writes=0,msi_writes=0,fetch_accepts=0;
int host_stalls=0,msi_stalls=0,status_during_stall=0,ingress_stalls=0;
int credit_stalls=0,configuration_stalls=0,doorbell_handoffs=0,epochs=0;
bit forced_msi_stall=0,base_change_armed=0;
bit host_was_held=0,controller_was_held=0,fetch_was_held=0;
logic [100:0] held_host;
logic [159:0] held_controller;
logic [167:0] held_fetch;
int unsigned host_rng=1;

always @(negedge pcie_clk) begin
  if(!common_cold_reset_n) begin dcm_wait=1;forced_msi_stall=0;end
  else begin
    host_rng=next_random(host_rng);
    dcm_wait=host_hold || host_rng[2:0]!=0;
    if(dcm_write && host_expected.size()!=0 && host_expected[0].interrupt_write &&
       !forced_msi_stall) begin dcm_wait=1;forced_msi_stall=1;end
`ifdef D2H_ORIGINAL_CONTROLLER
    // Stop before the next write edge: an overflowing vendor FIFO diagnostic
    // must not race the unique source-bound witness used by the strict runner.
    if(selected_case=="capacity-witness" && controller.ep_last_fifo_count>=128 &&
       controller.ep_last_fifo_wrreq && !controller.ep_last_fifo_rdreq)
      $fatal(1,"D2H_ORIGINAL_STATUS_CAPACITY count=%0d",controller.ep_last_fifo_count);
`endif
  end
end

always @(posedge pcie_clk) begin : controller_oracle
  host_event_t h;
  logic [159:0] ingress;
  int id;
  bit endpoint;
  if(common_cold_reset_n) begin
    if(cs && cswrite && !cswait) begin
      case(csaddr & 8'hfc)
        8'h00: begin expected_header[31:0]=csdata;
          if(selected_case=="base-witness" && host_was_held) base_change_armed=1;
        end
        8'h04: expected_header[63:32]=csdata;
        8'h10: expected_endpoints[csdata[6:0]]=1;
        8'h18: expected_control=csdata;
        default: begin end
      endcase
    end
    if(dtscs && dtswrite && !dtswait) begin
      ingress_expected.push_back(dtsdata[159:0]);dts_accepted++;
    end
    if(controller_was_held && !retirement_fault &&
       (!controller_valid || controller_data!==held_controller)) $fatal(1,"D2H_CONTROLLER_HOLD");
    controller_was_held=controller_valid&&!controller_ready;
    if(controller_was_held) begin held_controller=controller_data;ingress_stalls++;end
    if(fetch_was_held && (!fetch_req || {fetch_data,first_id}!==held_fetch))
      $fatal(1,"D2H_FETCH_HOLD");
    fetch_was_held=fetch_req&&!fetch_ack;
    if(fetch_was_held) held_fetch={fetch_data,first_id};
    if(fetch_req && fetch_ack) fetch_accepts++;
    if(dma.dma_wr_readmem.desc_fifo_wrreq !== rx_valid) $fatal(1,"D2H_NATIVE_PULSE_ENQUEUE");
    if(rx_valid) begin
      if(ingress_expected.size()==0) $fatal(1,"D2H_UNOWNED_CONTROLLER_DESCRIPTOR");
      ingress=ingress_expected.pop_front();
      if(rx_data!==ingress || rx_data[153]) $fatal(1,"D2H_CONTROLLER_DESCRIPTOR_ORDER");
      id=int'(rx_data[152:146]);endpoint=expected_endpoints[id];
      expected_endpoints[id]=0;
      if(!inject_failure && (expected_control[0] || endpoint)) begin
        h.address=expected_header+64'(4*id);h.data=1;
        h.descriptor_index=accepted_descriptors;h.interrupt_write=0;
        host_expected.push_back(h);host_expected_count++;
        if(endpoint && msi_interface[80]) begin
          h.address=msi_interface[63:0];h.data={16'b0,msi_interface[79:64]};
          h.interrupt_write=1;host_expected.push_back(h);host_expected_count++;
        end
      end
      accepted_descriptors++;
    end
    if(status_valid && dcm_write && dcm_wait) status_during_stall++;
    if(cswrite && cswait) configuration_stalls++;
    if(controller.ep_last_pntr_from_pending_wen && cswrite && csaddr==8'h10 &&
       controller.dcs_current_state==4'b0100) begin
      if(!cswait) $fatal(1,"D2H_DOORBELL_HANDOFF_COLLISION");
      doorbell_handoffs++;
    end
`ifndef D2H_ORIGINAL_CONTROLLER
    if(controller.c1_reserved==128 && controller.dma_tx_state==6'h08) credit_stalls++;
`endif
    if(selected_case=="failure-witness" && dcm_write) begin
      if(dcm_data!==32'h1 || dcm_address!==expected_header+64'd500)
        $fatal(1,"D2H_UNEXPECTED_ORIGINAL_FAILURE_ABI");
      $fatal(1,"D2H_ORIGINAL_FALSE_SUCCESS data=%08h address=%016h raw=0000007d expected_id=3",dcm_data,dcm_address);
    end
    if(selected_case=="base-witness" && base_change_armed && dcm_write &&
       host_expected.size()!=0 && dcm_address!==host_expected[0].address) begin
      if(dcm_address!==expected_header+64'd36) $fatal(1,"D2H_UNEXPECTED_ORIGINAL_BASE_ABI");
      $fatal(1,"D2H_ORIGINAL_BASE_RETARGET address=%016h",dcm_address);
    end
    if(host_was_held && {dcm_write,dcm_address,dcm_data,dcm_enable}!==held_host)
      $fatal(1,"D2H_DCM_HOLD");
    host_was_held=dcm_write&&dcm_wait;
    if(host_was_held) begin
      held_host={dcm_write,dcm_address,dcm_data,dcm_enable};host_stalls++;
      if(host_expected.size()!=0 && host_expected[0].interrupt_write) msi_stalls++;
    end
    if(dcm_write) begin
      if(host_expected.size()==0 || dcm_read || dcm_enable!==4'hf)
        $fatal(1,"D2H_UNOWNED_DCM_WRITE");
      h=host_expected[0];
      if({dcm_address,dcm_data}!=={h.address,h.data})
        $fatal(1,"D2H_DCM_ADDRESS_DATA expected=%016h/%08h actual=%016h/%08h",h.address,h.data,dcm_address,dcm_data);
      if(h.descriptor_index>=status_index || !descriptors[h.descriptor_index].status_seen)
        $fatal(1,"D2H_DCM_BEFORE_NATIVE_STATUS");
      if(!dcm_wait) begin
        h=host_expected.pop_front();host_accepted++;
        if(h.interrupt_write) msi_writes++; else status_writes++;
      end
    end
  end
end

// Simulation checks; these are not unbounded RTL proof claims.
assert property (@(posedge pcie_clk) disable iff(!common_cold_reset_n)
  rx_valid |-> controller_valid && controller_ready);
assert property (@(posedge pcie_clk) disable iff(!common_cold_reset_n)
  dtscs && dtswrite && dtswait |=> dtscs && dtswrite && $stable(dtsdata));
