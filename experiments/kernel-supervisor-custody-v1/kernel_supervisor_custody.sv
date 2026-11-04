// Isolated control composition. All ports share clk. Independent host/adapter
// certificates remain inputs; kernel custody never fabricates their drain.
module kernel_supervisor_custody #(
 parameter logic [255:0] COPY_SHA=0,TRIAD_SHA=0
)(
 input logic clk,cold_reset_n,backend_reset_n,
 input logic memory_ready,backend_init_failed,backend_ecc_interrupt,
 input logic adapter_fault,
 input logic [7:0] adapter_fault_code,
 input logic [34:0] adapter_fault_address,
 input logic adapter_fault_address_valid,adapter_quiescing,adapter_drained,
 input logic host_status_valid,host_stop_ack,host_dma_drained,host_desc_drained,host_writeback_drained,host_fault,
 input logic external_stop,cmd_valid,
 input logic [2:0] cmd_op,
 input logic read,write,
 input logic [7:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output wire waitrequest,readdatavalid,invalid_access,
 output wire [31:0] readdata,
 output wire cra_read,cra_write,
 output wire [29:0] cra_address,
 output wire [63:0] cra_writedata,
 output wire [7:0] cra_byteenable,
 input logic cra_waitrequest,cra_readdatavalid,
 input logic [63:0] cra_readdata,
 output wire launch_permit,host_submit_permit,kernel_stop_req,host_stop_req,adapter_quiesce_req,
 output wire [2:0] state_status,phase_status,
 output wire release_ready,fault_latched,cmd_ready,cmd_done,cmd_accepted,
 output wire [3:0] cmd_reason,
 output wire [15:0] fault_history,
 output wire kernel_idle,kernel_stop_ack,kernel_fault,launch_owned,read_pending,write_pending,
 output wire mailbox_write_permit
);
 wire custody_write_permit,busy,launch_kernel;
 // Coherent same-clock status becomes valid after reset initialization. This is
 // not a CDC synchronizer for independently arriving status bits. Backend loss
 // is reported by sticky custody fault; the coherent status itself remains valid.
 logic status_initialized;
 always_ff @(posedge clk or negedge cold_reset_n)
  if(!cold_reset_n)status_initialized<=0;else status_initialized<=1;
 wire kernel_status_valid=cold_reset_n&&status_initialized;
 assign mailbox_write_permit=launch_permit&&custody_write_permit;
 kernel_cra_mailbox_guarded mailbox(
  .clk,.cold_reset_n,.write_permit(mailbox_write_permit),.write_pending,
  .read,.write,.address,.writedata,.byteenable,.waitrequest,.readdatavalid,.readdata,.invalid_access,
  .cra_read,.cra_write,.cra_address,.cra_writedata,.cra_byteenable,.cra_waitrequest,.cra_readdatavalid,.cra_readdata);
 kernel_launch_custody #(.COPY_SHA(COPY_SHA),.TRIAD_SHA(TRIAD_SHA)) custody(
  .clk,.cold_reset_n,.backend_reset_n,.stop_req(kernel_stop_req),.write_pending,
  .cra_read,.cra_write,.cra_address,.cra_writedata,.cra_readdata,.cra_byteenable,.cra_waitrequest,.cra_readdatavalid,
  .write_permit(custody_write_permit),.busy,.kernel_idle,.kernel_stop_ack,.fault(kernel_fault),.launch_owned,.launch_kernel,.read_pending);
 platform_supervisor supervisor(
  .clk,.cold_reset_n,.memory_ready,.backend_init_failed,.backend_ecc_interrupt,
  .adapter_fault,.adapter_fault_code,.adapter_fault_address,.adapter_fault_address_valid,.adapter_quiescing,.adapter_drained,
  .kernel_status_valid,.kernel_stop_ack,.kernel_idle,.kernel_fault,
  .host_status_valid,.host_stop_ack,.host_dma_drained,.host_desc_drained,.host_writeback_drained,.host_fault,.external_stop,
  .cmd_valid,.cmd_op,.clear_valid(1'b0),.clear_mask(16'b0),
  .launch_permit,.host_submit_permit,.kernel_stop_req,.host_stop_req,.adapter_quiesce_req,
  .state_status,.phase_status,.release_ready,.fault_latched,.fault_history,
  .fault_pending(),.first_fault_code(),.first_adapter_code(),.first_adapter_address(),.first_adapter_address_valid(),
  .cmd_ready,.cmd_done,.cmd_accepted,.cmd_reason,.clear_done(),.clear_blocked(),.reset_request(),.epoch_advance());
endmodule
