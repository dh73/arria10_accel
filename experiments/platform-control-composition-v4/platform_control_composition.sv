// Synthesizable control only. clk is the kernel/adapter/supervisor domain.
// All status/context/command inputs must be coherent in clk; only BAR2 crosses.
// A coordinated cold reset defines a new epoch with no prior untracked starts.
module platform_control_composition #(
 parameter int ADDR_W=35,BAR2_APERTURE_BITS=15,SOURCE_PROFILE=0,
 parameter logic [255:0] SOURCE_ID=0,BUILD_ID=0,COPY_SHA=0,TRIAD_SHA=0,
 parameter logic [31:0] MGMT_SPACE=0,CRA_SPACE=0,
 parameter logic [63:0] CRA_BASE=0
)(
  input  logic clk, cold_reset_n,
  input  logic memory_ready, backend_init_failed, backend_ecc_interrupt,
  input  logic adapter_fault,
  input  logic [7:0] adapter_fault_code,
  input  logic [ADDR_W-1:0] adapter_fault_address,
  input  logic adapter_fault_address_valid, adapter_quiescing, adapter_drained,
  input  logic host_status_valid, host_stop_ack,
  input  logic host_dma_drained, host_desc_drained, host_writeback_drained,
  input  logic host_fault, external_stop,
  input  logic cmd_valid,
  input  logic [2:0] cmd_op,
  input  logic clear_valid,
  input  logic [15:0] clear_mask,
  output logic launch_permit, host_submit_permit,
  output logic kernel_stop_req, host_stop_req, adapter_quiesce_req,
  output logic [2:0] state_status, phase_status,
  output logic release_ready, fault_latched,
  output logic [15:0] fault_history, fault_pending, first_fault_code,
  output logic [7:0] first_adapter_code,
  output logic [ADDR_W-1:0] first_adapter_address,
  output logic first_adapter_address_valid,
  output logic cmd_ready, cmd_done, cmd_accepted,
  output logic [3:0] cmd_reason,
  output logic clear_done,
  output logic [15:0] clear_blocked,
  output logic reset_request, epoch_advance,
 input logic pcie_clk,backend_reset_n,context_valid,health_valid,
 input logic [127:0] session,
 input logic [63:0] epoch,
 input logic read,write,
 input logic [63:0] address,
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
 output wire kernel_idle,kernel_stop_ack,kernel_fault,
 output wire context_bound,context_guard_fault,context_guard_live,
 output wire [127:0] bound_session,
 output wire [63:0] bound_epoch,
 output wire launch_owned,read_pending,write_pending,mailbox_write_permit
);
 wire custody_write_permit,busy,launch_kernel,custody_fault;
 platform_context_guard context_guard(.clk,.cold_reset_n,.context_valid,.session,.epoch,
  .bound(context_bound),.live(context_guard_live),.fault(context_guard_fault),.bound_session,.bound_epoch);
 assign kernel_fault=custody_fault || context_guard_fault || (context_bound && !context_guard_live);
 wire supervisor_launch_permit,supervisor_host_submit_permit;
 logic status_initialized;
 always_ff @(posedge clk or negedge cold_reset_n)
  if(!cold_reset_n)status_initialized<=0;else status_initialized<=1;
 wire kernel_status_valid=cold_reset_n&&status_initialized&&context_bound;
 localparam logic [64:0] CRA_END={1'b0,CRA_BASE}+65'd512;
 localparam logic CONFIG_OK=ADDR_W>=32 && ADDR_W<=41 && BAR2_APERTURE_BITS>=9 && BAR2_APERTURE_BITS<=63 &&
  SOURCE_ID!=0 && BUILD_ID!=0 && CRA_BASE[2:0]==0 && !CRA_END[64] &&
  (MGMT_SPACE!=CRA_SPACE || CRA_END<=65'd256 || CRA_BASE>=64'd512);
 wire context_live=((CONFIG_OK && context_guard_live && health_valid)===1'b1);
 // Unbound initialization stays HOLD; unavailable kernel status blocks START.
 // Once bound, loss/mismatch requests stop without erasing accepted custody.
 wire stop_control=external_stop || (context_bound && !context_live);
 assign launch_permit=supervisor_launch_permit && custody_write_permit && context_live;
 assign host_submit_permit=supervisor_host_submit_permit && context_live;
 assign mailbox_write_permit=launch_permit;
 kernel_launch_custody_profiles #(.SOURCE_PROFILE(SOURCE_PROFILE),.COPY_SHA(COPY_SHA),.TRIAD_SHA(TRIAD_SHA)) custody(
  .clk,.cold_reset_n,.backend_reset_n,.stop_req(kernel_stop_req),.write_pending,
  .cra_read,.cra_write,.cra_address,.cra_writedata,.cra_readdata,.cra_byteenable,.cra_waitrequest,.cra_readdatavalid,
  .write_permit(custody_write_permit),.busy,.kernel_idle,.kernel_stop_ack,.fault(custody_fault),.launch_owned,.launch_kernel,.read_pending);
 platform_supervisor_address_width #(.ADDR_W(ADDR_W)) supervisor(
  .clk,.cold_reset_n,.memory_ready,.backend_init_failed,.backend_ecc_interrupt,
  .adapter_fault,.adapter_fault_code,.adapter_fault_address,.adapter_fault_address_valid,.adapter_quiescing,.adapter_drained,
  .kernel_status_valid,.kernel_stop_ack,.kernel_idle,.kernel_fault,
  .host_status_valid,.host_stop_ack,.host_dma_drained,.host_desc_drained,.host_writeback_drained,.host_fault,
  .external_stop(stop_control),.cmd_valid,.cmd_op,.clear_valid,.clear_mask,
  .launch_permit(supervisor_launch_permit),.host_submit_permit(supervisor_host_submit_permit),
  .kernel_stop_req,.host_stop_req,.adapter_quiesce_req,.state_status,.phase_status,.release_ready,.fault_latched,
  .fault_history,.fault_pending,.first_fault_code,.first_adapter_code,.first_adapter_address,.first_adapter_address_valid,
  .cmd_ready,.cmd_done,.cmd_accepted,.cmd_reason,.clear_done,.clear_blocked,.reset_request,.epoch_advance);
 shell_bar2_guarded_v2 #(.BAR2_APERTURE_BITS(BAR2_APERTURE_BITS),
  .SOURCE_ID(SOURCE_ID),.BUILD_ID(BUILD_ID),.MGMT_SPACE(MGMT_SPACE),.CRA_SPACE(CRA_SPACE),.CRA_BASE(CRA_BASE)) frontend(
  .pcie_clk,.kernel_clk(clk),.common_cold_reset_n(cold_reset_n),.context_valid(context_bound),.health_valid,
  .session(bound_session),.epoch(bound_epoch),
  .state_status,.phase_status,.release_ready,.fault_latched,.launch_permit,.host_submit_permit,
  .fault_history,.fault_pending,.first_fault_code,.first_adapter_code,
  .first_adapter_address(41'(first_adapter_address)),
  .first_adapter_address_valid,
  .read,.write,.address,.writedata,.byteenable,.waitrequest,.readdatavalid,.readdata,.invalid_access,.write_pending,
  .cra_read,.cra_write,.cra_address,.cra_writedata,.cra_byteenable,.cra_waitrequest,.cra_readdatavalid,.cra_readdata);
endmodule
