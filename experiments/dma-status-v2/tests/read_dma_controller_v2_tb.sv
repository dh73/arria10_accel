// SPDX-License-Identifier: BSD-3-Clause
`timescale 1ns/1ps
module read_dma_controller_v2_tb;
logic clk = 0, rstn = 0, desc_valid = 0;
always #5 clk = ~clk;
logic [159:0] desc = 0;
wire ready, wr, tx_push, arb, status_valid, status_ready;
wire ack_valid, engine_fault, controller_fault;
wire [31:0] status_data, ack_data;
logic cs = 0, cswrite = 0;
logic [7:0] csaddr = 0;
logic [31:0] csdata = 0;
logic host_stall = 1, diagnostic_ready = 0;
wire cswait, host_write, diagnostic_valid;
wire [63:0] host_address;
wire [31:0] host_data, diagnostic_data;
wire [3:0] host_be;
int requested_id = 7, statuses = 0, host_writes = 0, diagnostics = 0, cycles = 0;
logic [31:0] observed_status = 0;
logic [63:0] held_address;
logic [31:0] held_data;
bit held_write = 0;
altpcieav_dma_rd_candidate_v2 #(
.DMA_WIDTH(256), .DMA_BE_WIDTH(32), .RDDMA_AVL_ADDR_WIDTH(64),
.DEVICE_FAMILY("Arria 10")
) engine (
.Clk_i(clk), .Rstn_i(rstn), .RdDmaWrite_o(wr), .RdDmaAddress_o(),
.RdDmaWriteData_o(), .RdDmaBurstCount_o(), .RdDmaWriteEnable_o(),
.RdDmaWaitRequest_i(1'b0), .RdDmaRxData_i(desc), .RdDmaRxValid_i(desc_valid),
.RdDmaRxReady_o(ready), .RdDmaTxData_o(status_data), .RdDmaTxValid_o(status_valid),
.RdDmaTxReady_i(status_ready), .RdDmaAckValid_i(ack_valid), .RdDmaAckData_i(ack_data),
.RdDMACntrlReady_o(), .ContractFault_o(engine_fault),
.RxFifoRdReq_o(), .RxFifoDataq_i(266'b0), .RxFifoCount_i(4'b0),
.PreDecodeTagRdReq_o(), .PreDecodeTag_i(8'b0), .PreDecodeTagCount_i(4'b0),
.TxFifoWrReq_o(tx_push), .TxFifoData_o(), .TxFifoCount_i(4'b0),
.RdDMACntrlLoad_i(1'b0), .RdDMACntrlData_i(32'b0), .RdDMAStatus_o(),
.RdDMmaArbReq_o(arb), .RdDMmaArbGranted_i(arb), .BusDev_i(13'h100),
.DevCsr_i(32'b0), .MasterEnable_i(1'b0),
.ko_cpl_spc_header(8'hff), .ko_cpl_spc_data(12'hfff)
);
altpcie_dynamic_control_candidate_v2 controller (
.Clk_i(clk), .Rstn_i(rstn), .MsiInterface_i(82'b0),
.DCSChipSelect_i(cs), .DCSWrite_i(cswrite), .DCSAddress_i(csaddr),
.DCSWriteData_i(csdata), .DCSByteEnable_i(4'hf), .DCSRead_i(1'b0),
.DCSReadData_o(), .DCSWaitRequest_o(cswait),
.DCMAddress_o(host_address), .DCMWrite_o(host_write), .DCMWriteData_o(host_data),
.DCMRead_o(), .DCMByteEnable_o(host_be), .DCMWaitRequest_i(host_stall),
.DCMReadData_i(32'b0), .DCMReadDataValid_i(1'b0),
.DTSChipSelect_i(1'b0), .DTSWrite_i(1'b0), .DTSBurstCount_i(5'b0),
.DTSAddress_i(8'b0), .DTSWriteData_i(256'b0), .DTSWaitRequest_o(),
.DmaTxData_o(), .DmaTxValid_o(), .DmaTxReady_i(1'b1),
.DmaRxData_i(status_data), .DmaRxValid_i(status_valid), .DmaRxReady_o(status_ready),
.DmaAckValid_o(ack_valid), .DmaAckData_o(ack_data), .FetchStatusReady_i(1'b0),
.StatusDiagnosticValid_o(diagnostic_valid), .StatusDiagnosticReady_i(diagnostic_ready),
.StatusDiagnosticData_o(diagnostic_data), .StatusProtocolFault_o(controller_fault),
.WrDescTxData_o(), .WrDescTxReq_o(), .WrDescTxAck_i(1'b0),
.WrDescTxAck_o(), .WrDescTxReq_i(1'b0), .WrDescTxData_i(160'b0)
);
task automatic write_control(input logic [7:0] address, input logic [31:0] value);
@(negedge clk); csaddr = address; csdata = value; cs = 1; cswrite = 1;
#1;
while (cswait) begin @(negedge clk); #1; end
@(posedge clk); @(negedge clk); cs = 0; cswrite = 0;
endtask
always @(posedge clk) begin
cycles++;
if (cycles > 20000) $fatal(1, "controller integration watchdog");
if (rstn) begin
if (tx_push || wr) $fatal(1, "master-disabled engine issued payload");
if (engine_fault || controller_fault) $fatal(1, "unexpected engine/controller protocol fault");
if (ack_valid) $fatal(1, "error authorized retirement");
if (status_valid && status_ready) begin
statuses++;
observed_status = status_data;
if (status_data[31:28] !== 4'h2 || status_data[27:24] !== 4'h1 ||
status_data[23:16] == 0 || status_data[11:8] !== 4'h6 ||
status_data[7:0] !== 8'(requested_id))
$fatal(1, "wrong retained error status %h", status_data);
end
if (held_write && ({host_write,host_address,host_data,host_be} !== {1'b1,held_address,held_data,4'hf}))
$fatal(1, "host error write changed under waitrequest");
held_write = host_write && host_stall;
if (held_write) begin held_address = host_address; held_data = host_data; end
if (host_write && !host_stall) begin
if (requested_id >= 128 || statuses != 1 || host_address !== (64'h8000 + 4 * requested_id) ||
host_data !== observed_status || host_data === 32'h1 || host_be !== 4'hf)
$fatal(1, "controller false success or wrong identity addr=%h data=%h", host_address, host_data);
host_writes++;
end
if (diagnostic_valid && diagnostic_ready) begin
if (requested_id < 128 || statuses != 1 || diagnostic_data !== observed_status)
$fatal(1, "wrong reserved-ID error route %h", diagnostic_data);
diagnostics++;
end
end
end
initial begin
if (!$value$plusargs("ID=%d", requested_id)) requested_id = 7;
if (requested_id < 0 || requested_id > 255) $fatal(1, "bad ID");
repeat (5) @(negedge clk); rstn = 1;
write_control(8'h00, 32'h8000);
write_control(8'h18, 32'h1);
@(negedge clk);
desc[63:0] = 64'h1000; desc[127:64] = 64'h2000;
desc[145:128] = 18'd64; desc[153:146] = 8'(requested_id);
desc_valid = 1;
#1;
while (!ready) begin @(negedge clk); #1; end
@(posedge clk); @(negedge clk); desc_valid = 0;
wait (statuses == 1);
if (requested_id < 128) begin
wait (host_write);
repeat (12) @(negedge clk);
host_stall = 0;
wait (host_writes == 1);
end else begin
wait (diagnostic_valid);
repeat (12) @(negedge clk);
if (host_write) $fatal(1, "fetch ID aliased data flag");
diagnostic_ready = 1;
wait (diagnostics == 1);
@(negedge clk); diagnostic_ready = 0;
end
repeat (12) @(negedge clk);
if (statuses != 1 || host_writes != (requested_id < 128 ? 1 : 0) || diagnostics != (requested_id >= 128 ? 1 : 0))
$fatal(1, "duplicate error notification");
desc_valid = 1;
repeat (12) begin
@(negedge clk);
if (ready) $fatal(1, "error diagnostic released owner identity");
end
desc_valid = 0;
$display("PASS actual engine/controller candidate-v2 master-disabled ID=%0d raw=%h", requested_id, observed_status);
$finish;
end
endmodule
