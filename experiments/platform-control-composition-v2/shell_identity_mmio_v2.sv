// SPDX-License-Identifier: BSD-3-Clause
// Single clock domain; context/health must already be coherent in clk.
// This frontend assigns no physical BAR and grants no DMA admission.
module shell_identity_mmio_v2 #(
 parameter logic [255:0] SOURCE_ID='0, BUILD_ID='0,
 parameter logic [31:0] MGMT_SPACE='0, CRA_SPACE='0,
 parameter logic [63:0] MGMT_BASE='0, CRA_BASE='0, CRA_BYTES=512
)(
 input logic clk,cold_reset_n,context_valid,
 input logic [127:0] session,
 input logic [63:0] epoch,
 input logic health_valid,
 input logic [2:0] state_status,phase_status,
 input logic release_ready,fault_latched,launch_permit,host_submit_permit,
 input logic [15:0] fault_history,fault_pending,first_fault_code,
 input logic [7:0] first_adapter_code,
 input logic [40:0] first_adapter_address,
 input logic first_adapter_address_valid,
 input logic read,write,
 input logic [63:0] address,
 input logic [3:0] byteenable,
 output logic waitrequest,readdatavalid,
 output logic [31:0] readdata,
 output logic invalid_access
);
 logic req_valid,req_ready,rsp_valid,rsp_error;
 logic [15:0] req_address;
 logic [31:0] rsp_data;
 logic selected,rejected_q;
 // Subtraction is used only after the lower-bound check; no base+size wrap.
 // Match the identity core's four-state simulation normalization. This
 // rejects unknown bus addresses in simulation; it is not metastability detection.
 assign selected=(((address>=MGMT_BASE) && ((address-MGMT_BASE)<256) &&
                   address[1:0]==0) === 1'b1);
 assign req_valid=cold_reset_n && read && !write && selected;
 assign req_address=16'(address-MGMT_BASE);
 assign waitrequest=!cold_reset_n || (read && !write && selected && !req_ready);
 assign readdatavalid=rsp_valid || rejected_q;
 assign readdata=(rejected_q || rsp_error) ? 32'hffffffff : rsp_data;
 always_ff @(posedge clk or negedge cold_reset_n) begin
  if(!cold_reset_n) begin rejected_q<=0;invalid_access<=0;end
  else begin
   rejected_q<=read && !waitrequest && (write || !selected);
   if((write && !waitrequest) || (read && !waitrequest && (!selected || byteenable!=4'hf)) || rsp_error)
    invalid_access<=1;
  end
 end
 shell_identity_v2 #(.SOURCE_ID(SOURCE_ID),.BUILD_ID(BUILD_ID),.MGMT_SPACE(MGMT_SPACE),
 .CRA_SPACE(CRA_SPACE),.MGMT_BASE(MGMT_BASE),.CRA_BASE(CRA_BASE),.CRA_BYTES(CRA_BYTES)) identity (
 .clk,.cold_reset_n,.context_valid,.session,.epoch,.health_valid,.state_status,.phase_status,
 .release_ready,.fault_latched,.launch_permit,.host_submit_permit,.fault_history,.fault_pending,
 .first_fault_code,.first_adapter_code,.first_adapter_address,.first_adapter_address_valid,
 .req_valid,.req_address,.req_byteenable(byteenable),.req_ready,.rsp_valid,.rsp_error,.rsp_data);
endmodule
