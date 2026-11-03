// Combinational lane mapping only, not an Avalon transaction adapter.
// Caller must gate admission with address_valid and retain the accepted lane
// until its read response. No CDC, reset/drain, ECC or writeack logic here.
// Address contract: aligned byte address in the source's 2 GiB aperture.
module kernel_ddr_lane_map (
  input  logic [34:0] byte_address,
  input  logic [63:0] word_writedata,
  input  logic [7:0] word_byteenable,
  input  logic [511:0] line_readdata,
  output logic address_valid,
  output logic [24:0] line_address,
  output logic [2:0] word_lane,
  output logic [511:0] line_writedata,
  output logic [63:0] line_byteenable,
  output logic [63:0] word_readdata
);
  always_comb begin
    address_valid = (byte_address[34:31] == 4'b0) &&
                    (byte_address[2:0] == 3'b0);
    line_address = '0;
    word_lane = '0;
    line_writedata = '0;
    line_byteenable = '0;
    word_readdata = '0;
    if (address_valid) begin
      line_address = byte_address[30:6];
      word_lane = byte_address[5:3];
      line_writedata[64 * word_lane +: 64] = word_writedata;
      line_byteenable[8 * word_lane +: 8] = word_byteenable;
      word_readdata = line_readdata[64 * word_lane +: 64];
    end
  end
endmodule
