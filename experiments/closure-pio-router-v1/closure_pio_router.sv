// Route the owned closure window before the normal BAR2 CDC path. Input is
// already HIP-decoded BAR2. Preserve the normal path's single-outstanding
// backpressure even for local closure accesses, so responses cannot overtake.
module closure_pio_router #(parameter int BAR2_APERTURE_BITS=15)(
 input logic clk,cold_reset_n,
 input logic read,write,
 input logic [63:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output wire waitrequest,readdatavalid,
 output wire [31:0] readdata,
 output wire normal_read,normal_write,
 input logic normal_waitrequest,normal_readdatavalid,
 input logic [31:0] normal_readdata,
 input logic context_valid,context_fault,
 input logic [191:0] context_identity,
 input logic reopen_request,
 input logic [63:0] reopen_round,
 output wire reopen_ack,upstream_closed,fault,
 output wire [63:0] round
);
 localparam logic [63:0] MASK=64'hffffffffffffffff >> (64-BAR2_APERTURE_BITS);
 wire [63:0] relative_address=address & MASK;
 wire selected=(BAR2_APERTURE_BITS>=10 && BAR2_APERTURE_BITS<=63) &&
               relative_address>=832 && relative_address<880;
 wire local_valid;wire [31:0] local_data;
 assign waitrequest=!cold_reset_n || normal_waitrequest;
 assign normal_read=cold_reset_n && read && !selected;
 assign normal_write=cold_reset_n && write && !selected;
 assign readdatavalid=local_valid || normal_readdatavalid;
 assign readdata=local_valid?local_data:normal_readdata;
 upstream_closure_mailbox closure(
  .clk,.cold_reset_n,.context_valid,.context_fault,.context_identity,
  .read(read && selected && !waitrequest),.write(write && selected && !waitrequest),
  .address(6'(relative_address-64'd832)),.writedata,.byteenable,
  .readdatavalid(local_valid),.readdata(local_data),
  .reopen_request,.reopen_round,.reopen_ack,.round,.upstream_closed,.fault);
endmodule
