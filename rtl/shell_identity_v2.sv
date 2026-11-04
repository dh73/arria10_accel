// SPDX-License-Identifier: BSD-3-Clause
`default_nettype none
// NEW local management interface. No PCI BAR address is implied.
// All inputs are synchronous/coherent in clk, the common EMIF clock.
// Assert cold_reset_n asynchronously; synchronize its deassertion externally.
module shell_identity_v2 #(
  parameter logic [255:0] SOURCE_ID = '0,
  parameter logic [255:0] BUILD_ID = '0,
  parameter logic [31:0] MGMT_SPACE = '0,
  parameter logic [31:0] CRA_SPACE = '0,
  parameter logic [63:0] MGMT_BASE = '0,
  parameter logic [63:0] CRA_BASE = '0,
  parameter logic [63:0] CRA_BYTES = '0
) (
  input  logic clk, cold_reset_n,
  input  logic context_valid,
  input  logic [127:0] session,
  input  logic [63:0] epoch,
  input  logic health_valid,
  input  logic [2:0] state_status, phase_status,
  input  logic release_ready, fault_latched, launch_permit, host_submit_permit,
  input  logic [15:0] fault_history, fault_pending, first_fault_code,
  input  logic [7:0] first_adapter_code,
  input  logic [40:0] first_adapter_address,
  input  logic first_adapter_address_valid,
  input  logic req_valid,
  input  logic [15:0] req_address,
  input  logic [3:0] req_byteenable,
  output logic req_ready,
  output logic rsp_valid, rsp_error,
  output logic [31:0] rsp_data
);
  function automatic logic one(input logic value);
    case (value)
      1'b1: one = 1'b1;
      default: one = 1'b0;
    endcase
  endfunction

  // Four-state simulation normalization, not physical metastability detection.
  // Narrower actual arguments are zero-extended.
  function automatic logic known(input logic [767:0] value);
    case (^value)
      1'b0, 1'b1: known = 1'b1;
      default: known = 1'b0;
    endcase
  endfunction

  localparam logic [64:0] MGMT_END = {1'b0,MGMT_BASE} + 65'd256;
  localparam logic [64:0] CRA_END = {1'b0,CRA_BASE} + {1'b0,CRA_BYTES};
  localparam logic PARAM_OK =
    known({SOURCE_ID,BUILD_ID,MGMT_SPACE,CRA_SPACE,
           MGMT_BASE,CRA_BASE,CRA_BYTES}) &&
    SOURCE_ID != 256'b0 && BUILD_ID != 256'b0 &&
    CRA_BYTES == 64'd512 &&
    MGMT_BASE[1:0] == 2'b00 && CRA_BASE[2:0] == 3'b000 &&
    !MGMT_END[64] && !CRA_END[64] &&
    ((MGMT_SPACE != CRA_SPACE) ||
     (MGMT_END <= {1'b0,CRA_BASE}) || (CRA_END <= {1'b0,MGMT_BASE}));

  // Words 32..42: session, epoch, and the five diagnostic health words.
  logic [351:0] sample_q, sample_d;
  logic [159:0] health_candidate;
  logic captured_context_q, context_ok;
  logic [31:0] sequence_q;
  logic exhausted_q, changed, blocked, live;
  logic address_ok;

  always_comb begin
    health_candidate = '0;
    health_candidate[0] = 1'b1;
    health_candidate[3:1] = state_status;
    health_candidate[6:4] = phase_status;
    health_candidate[7] = fault_latched;
    health_candidate[8] = release_ready;
    health_candidate[9] = launch_permit;
    health_candidate[10] = host_submit_permit;
    health_candidate[47:32] = fault_history;
    health_candidate[63:48] = fault_pending;
    health_candidate[79:64] = first_fault_code;
    health_candidate[87:80] = first_adapter_code;
    health_candidate[88] = first_adapter_address_valid;
    if (one(first_adapter_address_valid))
      health_candidate[136:96] = first_adapter_address;

    context_ok = one(context_valid) && known({session,epoch}) &&
                 session != 128'b0 && epoch != 64'b0;
    sample_d = '0;
    if (context_ok) begin
      sample_d[127:0] = session;
      sample_d[191:128] = epoch;
    end
    if (one(health_valid) && known(health_candidate) &&
        state_status <= 3'd6 && phase_status <= 3'd5)
      sample_d[351:192] = health_candidate;
  end

  assign changed = (captured_context_q != context_ok) || (sample_q != sample_d);
  // Refuse a publication that would wrap, including at this read edge.
  assign blocked = exhausted_q || ((sequence_q == 32'hffffffff) && changed);
  assign live = one(cold_reset_n) && one(PARAM_OK) && context_ok &&
    captured_context_q && sequence_q != 0 && !blocked &&
    session == sample_q[127:0] && epoch == sample_q[191:128];
  assign req_ready = one(cold_reset_n);
  assign address_ok = known(req_address) &&
    (req_address[15:8] == 8'b0) && (req_address[1:0] == 2'b00) &&
    (req_byteenable === 4'b1111);

  always_ff @(posedge clk or negedge cold_reset_n) begin
    if (!cold_reset_n) begin
      sample_q <= '0;
      captured_context_q <= 1'b0;
      sequence_q <= '0;
      exhausted_q <= 1'b0;
    end else if (!exhausted_q && changed) begin
      if (sequence_q == 32'hffffffff) begin
        exhausted_q <= 1'b1;
      end else begin
        sample_q <= sample_d;
        captured_context_q <= context_ok;
        sequence_q <= sequence_q + 32'd1;
      end
    end
  end

  function automatic logic [31:0] word_at(input logic [5:0] index);
    word_at = '0;
    if (index >= 6'd8 && index < 6'd16)
      word_at = SOURCE_ID[(index-6'd8)*32 +: 32];
    else if (index >= 6'd16 && index < 6'd24)
      word_at = BUILD_ID[(index-6'd16)*32 +: 32];
    else if (index >= 6'd32 && index <= 6'd42)
      word_at = sample_q[(index-6'd32)*32 +: 32];
    else case (index)
      0: word_at = 32'h31444941;
      1: word_at = 32'h00020000;
      2: word_at = 32'd2;
      3: word_at = 32'd256;
      4: word_at = 32'h0000001f;
      5: word_at = 32'h0000001f;
      6: word_at = live ? sequence_q : 32'b0;
      7: word_at = {30'b0,blocked,live};
      24: word_at = MGMT_SPACE;
      25: word_at = CRA_SPACE;
      26: word_at = MGMT_BASE[31:0];
      27: word_at = MGMT_BASE[63:32];
      28: word_at = CRA_BASE[31:0];
      29: word_at = CRA_BASE[63:32];
      30: word_at = CRA_BYTES[31:0];
      31: word_at = CRA_BYTES[63:32];
      default: word_at = 32'b0;
    endcase
  endfunction

  // Each req_valid && req_ready edge accepts exactly one full 32-bit read.
  // rsp_* is registered immediately after that edge. There is no response
  // backpressure: the external bridge must reserve response capacity.
  // The bridge must cancel old responses on reset/configuration discontinuity.
  always_ff @(posedge clk or negedge cold_reset_n) begin
    if (!cold_reset_n) begin
      rsp_valid <= 1'b0;
      rsp_error <= 1'b0;
      rsp_data <= '0;
    end else begin
      rsp_valid <= 1'b0;
      rsp_error <= 1'b0;
      rsp_data <= '0;
      if (one(req_valid)) begin
        rsp_valid <= 1'b1;
        rsp_error <= !address_ok;
        if (address_ok) rsp_data <= word_at(req_address[7:2]);
      end
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!cold_reset_n)
    1'b1 |=> sequence_q >= $past(sequence_q))
    else $fatal(1,"identity sequence wrapped");
  assert property (@(posedge clk) disable iff (!cold_reset_n)
    exhausted_q |=> exhausted_q && $stable({sequence_q,sample_q,captured_context_q}))
    else $fatal(1,"identity sequence exhaustion recovered without reset");
`endif
endmodule
`default_nettype wire
