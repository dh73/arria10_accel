// SPDX-License-Identifier: BSD-3-Clause
// Connect ONLY to the HIP's separately decoded BAR2 RXM port. Its read/write
// strobes must already be qualified by the HIP BAR2 hit, never raw shared RX.
// The selected C10 HIP uses bar2_address_width_mux_hwtcl=15 and forwards the
// original PCIe address. BAR bases are aperture-aligned by PCIe configuration.
// Preserve this parameter with the HIP configuration; this is not a decoder
// for unqualified host addresses. Offsets outside the 32-byte mailbox reject.
module hip_bar2_kernel_control #(
 parameter int BAR2_APERTURE_BITS=15
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
 wire [63:0] bar_offset;
 generate
  if(BAR2_APERTURE_BITS>=5 && BAR2_APERTURE_BITS<=63) begin: valid_width
   assign bar_offset={{(64-BAR2_APERTURE_BITS){1'b0}},address[BAR2_APERTURE_BITS-1:0]};
  end else begin: invalid_width
   assign bar_offset=64'hffffffffffffffff;
   initial $fatal(1,"HIP BAR2 aperture must be 5..63 bits");
  end
 endgenerate
 kernel_control_frontend #(.MAILBOX_BASE(0)) frontend(
  .pcie_clk,.kernel_clk,.common_cold_reset_n,.read,.write,.address(bar_offset),
  .writedata,.byteenable,.waitrequest,.readdatavalid,.readdata,.invalid_access,
  .cra_read,.cra_write,.cra_address,.cra_writedata,.cra_byteenable,
  .cra_waitrequest,.cra_readdatavalid,.cra_readdata);
endmodule
