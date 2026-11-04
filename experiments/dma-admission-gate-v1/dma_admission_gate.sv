// SPDX-License-Identifier: BSD-3-Clause
// One retained DCS offer. Stop closes new writes, never withdraws an old offer.
// upstream_closed must certify all host Prepared/transport handoffs are closed
// in this reset epoch; this module cannot generate that external certificate.
module dma_admission_gate (
  input logic clk, reset_n, submit_permit, stop_req, upstream_closed,
  input logic s_select, s_read, s_write,
  input logic [7:0] s_address,
  input logic [31:0] s_writedata,
  input logic [3:0] s_byteenable,
  output logic s_waitrequest,
  output logic [31:0] s_readdata,
  output logic m_select, m_read, m_write,
  output logic [7:0] m_address,
  output logic [31:0] m_writedata,
  output logic [3:0] m_byteenable,
  input logic m_waitrequest,
  input logic [31:0] m_readdata,
  output logic write_owned, stop_ack
);
  logic active, rd, wr;
  logic [7:0] address;
  logic [31:0] data;
  logic [3:0] be;
  logic capture, capture_write;
  always_comb begin
    capture=1'b0;
    // Fail closed for unknown permission/stop and malformed read+write.
    if (reset_n === 1'b1 && !active && s_select === 1'b1) begin
      if (s_read === 1'b1 && s_write === 1'b0) capture=1'b1;
      if (s_write === 1'b1 && s_read === 1'b0 &&
          submit_permit === 1'b1 && stop_req === 1'b0) capture=1'b1;
    end
    capture_write=capture && s_write;
    m_select=active; m_read=active && rd; m_write=active && wr;
    m_address=address; m_writedata=data; m_byteenable=be;
    s_waitrequest=!(active && m_waitrequest === 1'b0);
    s_readdata=m_readdata;
    write_owned=(active && wr) || capture_write;
    stop_ack=(reset_n === 1'b1 && stop_req === 1'b1 &&
              upstream_closed === 1'b1 && !write_owned);
  end
  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      active<=0; rd<=0; wr<=0; address<=0; data<=0; be<=0;
    end else if (active) begin
      if (m_waitrequest === 1'b0) active<=0;
    end else if (capture) begin
      active<=1; rd<=s_read; wr<=s_write;
      address<=s_address; data<=s_writedata; be<=s_byteenable;
    end
  end
endmodule
