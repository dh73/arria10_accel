// Isolated combined control frontend: decoded HIP BAR2 only.
// BAR2 offsets: kernel [0,32), identity [256,512), fence [512,552), control [576,608).
// Passive DDR snapshots [640,720); observed bus is in kernel_clk domain.
// Identity CRA_SPACE/BASE describe an explicitly declared logical CRA resource,
// not the 32-byte mailbox. Caller must bind transport, image and supervision.
// Context/health are coherent in kernel_clk. No admission authority is granted.
module shell_bar2_context_v1 #(
 parameter int BAR2_APERTURE_BITS=15,
 parameter logic [255:0] SOURCE_ID='0,BUILD_ID='0,
 parameter logic [31:0] MGMT_SPACE=0,CRA_SPACE=0,
 parameter logic [63:0] CRA_BASE=0
)(
 input logic pcie_clk,kernel_clk,common_cold_reset_n,
 output wire provisioned_valid,provisioned_fault,
 output wire [127:0] provisioned_session,
 output wire [63:0] provisioned_epoch,
 input logic context_valid,health_valid,
 input logic ddr_read,ddr_write,ddr_waitrequest,ddr_readdatavalid,
 input logic [63:0] ddr_byteenable,
 output wire control_cmd_valid,
 output wire [2:0] control_cmd_op,
 input logic control_cmd_ready,control_cmd_done,control_cmd_accepted,
 input logic [3:0] control_cmd_reason,
 input logic fence_admission_closed,fence_local_drained,fence_tx_checkpoint_empty,
 input logic fence_stop_requested,fence_reopen,
 output wire fence_ready,fence_settled,fence_fault,
 input logic [127:0] session,
 input logic [63:0] epoch,
 input logic [2:0] state_status,phase_status,
 input logic release_ready,fault_latched,launch_permit,host_submit_permit,
 input logic [15:0] fault_history,fault_pending,first_fault_code,
 input logic [7:0] first_adapter_code,
 input logic [40:0] first_adapter_address,
 input logic first_adapter_address_valid,
 input logic read,write,
 input logic [63:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output logic waitrequest,readdatavalid,
 output logic [31:0] readdata,
 output logic invalid_access,
 output wire write_pending,
 output logic cra_read,cra_write,
 output logic [29:0] cra_address,
 output logic [63:0] cra_writedata,
 output logic [7:0] cra_byteenable,
 input logic cra_waitrequest,cra_readdatavalid,
 input logic [63:0] cra_readdata
);
 localparam logic [63:0] MAILBOX_BASE=0,MGMT_BASE=256;
 localparam logic [63:0] BAR_MASK=(64'hffffffffffffffff >> (64-BAR2_APERTURE_BITS));
 wire width_ok=BAR2_APERTURE_BITS>=10 && BAR2_APERTURE_BITS<=63;
 wire [63:0] relative_address=width_ok?(address & BAR_MASK):64'hffffffffffffffff;
 wire m_read,m_write,m_wait,m_valid;
 wire [63:0] m_address;
 wire [31:0] m_writedata,m_readdata;
 wire [3:0] m_mask;
 wire selected=(((m_address>=MAILBOX_BASE) &&
                   ((m_address-MAILBOX_BASE)<64'd32))===1'b1);
 wire mb_wait,mb_valid,mb_invalid;
 wire [31:0] mb_data;
 logic rejected_read,rejected_access;
 wire identity_selected=(((m_address>=MGMT_BASE) && ((m_address-MGMT_BASE)<256))===1'b1);
 wire fence_selected=(((m_address>=512) && (m_address<552))===1'b1);
 wire fence_valid;wire [31:0] fence_data;
 wire control_selected=(((m_address>=576) && (m_address<608))===1'b1);
 wire control_valid,control_invalid,control_busy;wire [31:0] control_data;
 wire metrics_selected=(((m_address>=640) && (m_address<720))===1'b1);
 wire metrics_valid,metrics_invalid;wire [31:0] metrics_data;
 wire provision_selected=(((m_address>=768) && (m_address<800))===1'b1);
 wire provision_reply,provision_invalid;wire [31:0] provision_data;
 wire id_wait,id_valid,id_invalid;
 wire [31:0] id_data;
 assign m_wait=selected?mb_wait:(identity_selected?id_wait:1'b0);
 assign m_valid=rejected_read || mb_valid || id_valid || fence_valid || control_valid || metrics_valid || provision_reply;
 assign m_readdata=provision_reply?provision_data:metrics_valid?metrics_data:rejected_read?32'hffffffff:(id_valid?id_data:(fence_valid?fence_data:(control_valid?control_data:mb_data)));
 // Kernel-domain diagnostic; synchronize before use in the PCIe domain.
 assign invalid_access=rejected_access || mb_invalid || id_invalid || fence_fault || control_invalid || metrics_invalid || provision_invalid;
 always_ff @(posedge kernel_clk or negedge common_cold_reset_n) begin
  if(!common_cold_reset_n)begin rejected_read<=0;rejected_access<=0;end
  else begin
   rejected_read<=m_read && !m_wait && !selected && !identity_selected && !fence_selected && !control_selected && !metrics_selected && !provision_selected;
   if((m_read || m_write) && !m_wait && !selected && !identity_selected && !fence_selected && !control_selected && !metrics_selected && !provision_selected)rejected_access<=1;
  end
 end
 pio_cdc_bridge crossing(
  .src_clk(pcie_clk),.dst_clk(kernel_clk),.common_cold_reset_n,
  .s_read(read),.s_write(write),.s_address(relative_address),.s_writedata(writedata),
  .s_byteenable(byteenable),.s_waitrequest(waitrequest),
  .s_readdatavalid(readdatavalid),.s_readdata(readdata),
  .m_read,.m_write,.m_address,.m_writedata,.m_byteenable(m_mask),
  .m_waitrequest(m_wait),.m_readdatavalid(m_valid),.m_readdata);
 wire write_permit=((launch_permit && context_valid && health_valid && !fault_latched &&
                         session!=0 && epoch!=0)===1'b1);
 kernel_cra_mailbox_guarded mailbox(
  .clk(kernel_clk),.cold_reset_n(common_cold_reset_n),.write_permit,.write_pending,
  .read(m_read && selected),.write(m_write && selected),
  .address(8'(m_address-MAILBOX_BASE)),.writedata(m_writedata),.byteenable(m_mask),
  .waitrequest(mb_wait),.readdatavalid(mb_valid),.readdata(mb_data),
  .invalid_access(mb_invalid),.cra_read,.cra_write,.cra_address,.cra_writedata,
  .cra_byteenable,.cra_waitrequest,.cra_readdatavalid,.cra_readdata);
 shell_identity_mmio_v2 #(.SOURCE_ID(SOURCE_ID),.BUILD_ID(BUILD_ID),
 .MGMT_SPACE(MGMT_SPACE),.CRA_SPACE(CRA_SPACE),.MGMT_BASE(MGMT_BASE),
 .CRA_BASE(CRA_BASE),.CRA_BYTES(512)) identity(
 .clk(kernel_clk),.cold_reset_n(common_cold_reset_n),.context_valid,.session,.epoch,
 .health_valid,.state_status,.phase_status,.release_ready,.fault_latched,
 .launch_permit,.host_submit_permit,.fault_history,.fault_pending,.first_fault_code,
 .first_adapter_code,.first_adapter_address,.first_adapter_address_valid,
 .read(m_read && identity_selected),.write(m_write && identity_selected),
 .address(m_address),.byteenable(m_mask),.waitrequest(id_wait),.readdatavalid(id_valid),
 .readdata(id_data),.invalid_access(id_invalid));
 host_writeback_fence_round fence(
 .clk(kernel_clk),.cold_reset_n(common_cold_reset_n),.context_valid,.session,.epoch,
 .stop_requested(fence_stop_requested),.reopen(fence_reopen),
 .admission_closed(fence_admission_closed),.local_drained(fence_local_drained),.tx_checkpoint_empty(fence_tx_checkpoint_empty),
 .read(m_read && fence_selected),.write(m_write && fence_selected),
 .address(6'(m_address-64'd512)),.writedata(m_writedata),.byteenable(m_mask),
 .readdatavalid(fence_valid),.readdata(fence_data),
 .ready(fence_ready),.settled(fence_settled),.fault(fence_fault));
 supervisor_command_mailbox control(
 .clk(kernel_clk),.cold_reset_n(common_cold_reset_n),
 .write_permit(context_valid && health_valid && session!=0 && epoch!=0),
 .read(m_read && control_selected),.write(m_write && control_selected),
 .address(5'(m_address-64'd576)),.writedata(m_writedata),.byteenable(m_mask),
 .readdatavalid(control_valid),.readdata(control_data),.invalid_access(control_invalid),
 .cmd_valid(control_cmd_valid),.cmd_op(control_cmd_op),.cmd_ready(control_cmd_ready),
 .cmd_done(control_cmd_done),.cmd_accepted(control_cmd_accepted),.cmd_reason(control_cmd_reason),.busy(control_busy));
 ddr_traffic_mmio metrics(
 .clk(kernel_clk),.cold_reset_n(common_cold_reset_n),
 .read(m_read && metrics_selected),.write(m_write && metrics_selected),
 .address(7'(m_address-64'd640)),.writedata(m_writedata),.byteenable(m_mask),
 .readdatavalid(metrics_valid),.readdata(metrics_data),.invalid_access(metrics_invalid),
 .ddr_read,.ddr_write,.ddr_waitrequest,.ddr_readdatavalid,.ddr_byteenable);
 platform_context_mailbox provision(
 .clk(kernel_clk),.cold_reset_n(common_cold_reset_n),
 .read(m_read && provision_selected),.write(m_write && provision_selected),
 .address(6'(m_address-64'd768)),.writedata(m_writedata),.byteenable(m_mask),
 .readdatavalid(provision_reply),.readdata(provision_data),.invalid_access(provision_invalid),
 .context_valid(provisioned_valid),.fault(provisioned_fault),.session(provisioned_session),.epoch(provisioned_epoch));
endmodule
