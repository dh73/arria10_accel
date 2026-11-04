// SPDX-License-Identifier: BSD-3-Clause
// BAR-relative 32-byte command aperture; source PIO and kernel CRA have
// independent clocks. Shared cold reset only. Physical BAR mapping, image
// admission, CDC timing constraints and supervisor gates are external.
module kernel_control_frontend #(
 parameter logic [63:0] MAILBOX_BASE=0
)(
 input logic pcie_clk,kernel_clk,common_cold_reset_n,
 input logic read,write,
 input logic [63:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output logic waitrequest,readdatavalid,
 output logic [31:0] readdata,
 output logic invalid_access,
 output logic cra_read,cra_write,
 output logic [29:0] cra_address,
 output logic [63:0] cra_writedata,
 output logic [7:0] cra_byteenable,
 input logic cra_waitrequest,cra_readdatavalid,
 input logic [63:0] cra_readdata
);
 wire m_read,m_write,m_wait,m_valid;
 wire [63:0] m_address;
 wire [31:0] m_writedata,m_readdata;
 wire [3:0] m_mask;
 wire selected=(((m_address>=MAILBOX_BASE) &&
                   ((m_address-MAILBOX_BASE)<64'd32))===1'b1);
 wire mb_wait,mb_valid,mb_invalid;
 wire [31:0] mb_data;
 logic rejected_read,rejected_access;
 assign m_wait=selected?mb_wait:1'b0;
 assign m_valid=rejected_read || mb_valid;
 assign m_readdata=rejected_read?32'hffffffff:mb_data;
 // Kernel-domain diagnostic; synchronize before use in the PCIe domain.
 assign invalid_access=rejected_access || mb_invalid;
 always_ff @(posedge kernel_clk or negedge common_cold_reset_n) begin
  if(!common_cold_reset_n)begin rejected_read<=0;rejected_access<=0;end
  else begin
   rejected_read<=m_read && !m_wait && !selected;
   if((m_read || m_write) && !m_wait && !selected)rejected_access<=1;
  end
 end
 pio_cdc_bridge crossing(
  .src_clk(pcie_clk),.dst_clk(kernel_clk),.common_cold_reset_n,
  .s_read(read),.s_write(write),.s_address(address),.s_writedata(writedata),
  .s_byteenable(byteenable),.s_waitrequest(waitrequest),
  .s_readdatavalid(readdatavalid),.s_readdata(readdata),
  .m_read,.m_write,.m_address,.m_writedata,.m_byteenable(m_mask),
  .m_waitrequest(m_wait),.m_readdatavalid(m_valid),.m_readdata);
 kernel_cra_mailbox mailbox(
  .clk(kernel_clk),.cold_reset_n(common_cold_reset_n),
  .read(m_read && selected),.write(m_write && selected),
  .address(8'(m_address-MAILBOX_BASE)),.writedata(m_writedata),.byteenable(m_mask),
  .waitrequest(mb_wait),.readdatavalid(mb_valid),.readdata(mb_data),
  .invalid_access(mb_invalid),.cra_read,.cra_write,.cra_address,.cra_writedata,
  .cra_byteenable,.cra_waitrequest,.cra_readdatavalid,.cra_readdata);
endmodule
