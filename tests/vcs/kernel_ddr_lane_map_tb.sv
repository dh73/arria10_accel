`timescale 1ns/1ps
module kernel_ddr_lane_map_tb;
  logic [34:0] byte_address;
  logic [63:0] word_writedata;
  logic [7:0] word_byteenable;
  logic [511:0] line_readdata;
  wire address_valid;
  wire [24:0] line_address;
  wire [2:0] word_lane;
  wire [511:0] line_writedata;
  wire [63:0] line_byteenable, word_readdata;
  kernel_ddr_lane_map dut (.*);
  int checks = 0;
  task automatic check_mapping;
    logic valid_expected;
    logic [511:0] expected_data;
    logic [63:0] expected_be, expected_read;
    int offset;
    valid_expected = (byte_address < 35'h80000000) && ((byte_address % 8) == 0);
    expected_data = 0; expected_be = 0; expected_read = 0;
    offset = byte_address % 64;
    if (valid_expected) begin
      for (int b=0; b<8; b++) begin
        expected_data[(offset+b)*8 +: 8] = word_writedata[b*8 +: 8];
        expected_be[offset+b] = word_byteenable[b];
        expected_read[b*8 +: 8] = line_readdata[(offset+b)*8 +: 8];
      end
    end
    #1;
    if (address_valid !== valid_expected || line_writedata !== expected_data ||
        line_byteenable !== expected_be || word_readdata !== expected_read)
      $fatal(1, "lane data/valid mismatch address=%h mask=%h", byte_address, word_byteenable);
    if (valid_expected) begin
      if (line_address !== 25'(byte_address / 64) || word_lane !== 3'(offset / 8))
        $fatal(1, "lane address mismatch");
    end else if ({line_address,word_lane} !== '0) $fatal(1, "invalid address not zeroed");
    checks++;
  endtask
  initial begin
    for (int b=0; b<64; b++) line_readdata[b*8 +: 8] = 8'(b ^ 8'ha5);
    word_writedata = 64'h12345678abcdef90;
    for (int boundary=0; boundary<2; boundary++)
      for (int lane=0; lane<8; lane++)
        for (int mask=0; mask<256; mask++) begin
          byte_address = (boundary ? 35'h7fffffc0 : 0) + lane*8;
          word_byteenable = 8'(mask); check_mapping();
        end
    word_byteenable = 8'hff;
    for (int lane=0; lane<8; lane++)
      for (int b=0; b<64; b++) begin
        byte_address = lane*8; word_writedata = 64'b1 << b; check_mapping();
      end
    for (int b=31; b<35; b++) begin
      byte_address = 35'b1 << b; check_mapping();
    end
    for (int low=1; low<8; low++) begin
      byte_address = 35'h7fffffc0 + low; check_mapping();
    end
    $display("PASS lane mapper checks=%0d",checks);
    $finish;
  end
endmodule
