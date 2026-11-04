// Separate D2H-head candidate; original composition and arbiter stay frozen.
// core_* is an abstract line requester, not a qualified processor integration.
module dma_memory_path_line_coalescing_candidate (
  input logic pcie_clk,user_clk,common_cold_reset_n,
  input logic app_nreset_status,backend_reset_n,memory_ready,memory_failed,quiesce,
  input logic [63:0] rd_dma_address_o,wr_dma_address_o,
  input logic rd_dma_write_o,wr_dma_read_o,
  input logic [255:0] rd_dma_write_data_o,
  input logic [31:0] rd_dma_byte_enable_o,wr_dma_read_byte_enable_o,
  input logic [4:0] rd_dma_burst_count_o,wr_dma_burst_count_o,
  output wire rd_dma_wait_request_i,wr_dma_wait_request_i,
  output wire [255:0] wr_dma_read_data_i,
  output wire wr_dma_read_data_valid_i,busy,quiesced,fault,
  output wire [3:0] fault_code,
  output wire [63:0] fault_address,
  output wire [4:0] owned_beats,
  output wire ddr_lock,mux_fault,
  input logic [24:0] core_address,
  input logic core_read,core_write,
  input logic [511:0] core_writedata,
  input logic [63:0] core_byteenable,
  output wire core_waitrequest,core_readdatavalid,core_readdataerror,
  output wire [511:0] core_readdata,
  output wire [24:0] avm_address,
  output wire avm_read,avm_write,
  output wire [511:0] avm_writedata,
  output wire [63:0] avm_byteenable,
  output wire [0:0] avm_burstcount,
  input logic avm_waitrequest,avm_readdatavalid,avm_readdataerror,
  input logic [511:0] avm_readdata
);
  wire [1:0][24:0] addresses;
  wire [1:0] reads,writes,waits,valids,errors;
  wire [1:0][511:0] data;
  wire [1:0][63:0] masks;
  wire [511:0] response;
  wire [0:0] payload_burst;
  assign addresses[0]=core_address;
  assign reads[0]=core_read;
  assign writes[0]=core_write;
  assign data[0]=core_writedata;
  assign masks[0]=core_byteenable;
  assign core_waitrequest=waits[0];
  assign core_readdatavalid=valids[0];
  assign core_readdataerror=errors[0];
  assign core_readdata=response;
  dma_payload_line_coalescing_candidate payload (
    .pcie_clk,.user_clk,.common_cold_reset_n,.app_nreset_status,.backend_reset_n,
    .memory_ready,.memory_failed(memory_failed || mux_fault),.quiesce,
    .rd_dma_address_o,.rd_dma_write_o,.rd_dma_write_data_o,.rd_dma_byte_enable_o,
    .rd_dma_burst_count_o,.rd_dma_wait_request_i,
    .wr_dma_address_o,.wr_dma_read_o,.wr_dma_read_byte_enable_o,
    .wr_dma_burst_count_o,.wr_dma_wait_request_i,.wr_dma_read_data_i,.wr_dma_read_data_valid_i,
    .busy,.quiesced,.fault,.fault_code,.fault_address,.owned_beats,.ddr_lock,
    .avm_address(addresses[1]),.avm_read(reads[1]),.avm_write(writes[1]),
    .avm_writedata(data[1]),.avm_byteenable(masks[1]),.avm_burstcount(payload_burst),
    .avm_waitrequest(waits[1]),.avm_readdatavalid(valids[1]),
    .avm_readdataerror(errors[1]),.avm_readdata(response));
  arria10_dma_ddr_mux owner_mux (
    .clk(user_clk),.common_cold_reset_n,.backend_reset_n,.dma_lock(ddr_lock),
    .req_address(addresses),.req_read(reads),.req_write(writes),
    .req_writedata(data),.req_byteenable(masks),.req_waitrequest(waits),
    .rsp_valid(valids),.rsp_error(errors),.rsp_data(response),
    .avm_address,.avm_read,.avm_write,.avm_writedata,.avm_byteenable,.avm_burstcount,
    .avm_waitrequest,.avm_readdatavalid,.avm_readdataerror,.avm_readdata,.fault(mux_fault));
endmodule
