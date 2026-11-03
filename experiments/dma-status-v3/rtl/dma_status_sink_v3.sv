// SPDX-License-Identifier: BSD-3-Clause
// Same version-2 status words; four-phase local receipt custody replaces pulses.
module dma_status_sink_v3 #(
  parameter int DEPTH = 16
) (
  input logic clk, rstn,
  input logic s_valid,
  output logic s_ready,
  input logic [31:0] s_word,
  input logic s_msi,
  input logic [63:0] header_base,
  input logic [81:0] msi_interface,
  output logic dcm_write,
  output logic [63:0] dcm_address,
  output logic [31:0] dcm_data,
  output logic [3:0] dcm_byteenable,
  input logic dcm_waitrequest,
  output logic fetch_valid,
  input logic fetch_ready,
  output logic [31:0] fetch_word,
  output logic diagnostic_valid,
  input logic diagnostic_ready,
  output logic [31:0] diagnostic_word,
  output logic retired_ack_valid,
  output logic [31:0] retired_ack_word,
  input logic retired_ack_consumed,
  output logic protocol_fault,
  output logic [31:0] fault_word
);
import dma_status_v2_pkg::*;
localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
localparam int COUNT_W = $clog2(DEPTH + 1);
typedef struct packed {
  logic [31:0] word;
  logic [63:0] base;
  logic [63:0] msi_address;
  logic [15:0] msi_data;
  logic do_msi;
} entry_t;
typedef enum logic [3:0] {
  IDLE, FLAG, MSI, FETCH, DIAGNOSTIC, FETCH_FENCE, RECEIPT, RETURN_LOW, BAD
} state_t;
entry_t queue [DEPTH];
entry_t active;
logic [PTR_W-1:0] rd_ptr, wr_ptr;
logic [COUNT_W-1:0] count;
state_t state;
logic push, pop, flag_accept, msi_accept, fetch_accept, diagnostic_accept;
logic published_success;
function automatic logic [PTR_W-1:0] next_ptr(input logic [PTR_W-1:0] ptr);
  return ptr == DEPTH-1 ? '0 : ptr + 1'b1;
endfunction
assign s_ready = rstn && !protocol_fault && count < DEPTH;
assign push = s_valid && s_ready;
assign dcm_write = rstn && (state == FLAG || state == MSI);
assign dcm_address = state == MSI ? active.msi_address :
                    active.base + {55'b0, active.word[6:0], 2'b00};
assign dcm_data = state == MSI ? {16'b0, active.msi_data} :
                 status_v2_success(active.word) ? 32'h1 : active.word;
assign dcm_byteenable = 4'hf;
assign fetch_valid = rstn && state == FETCH;
assign fetch_word = active.word;
assign diagnostic_valid = rstn && state == DIAGNOSTIC;
assign diagnostic_word = active.word;
assign flag_accept = rstn && state == FLAG && !dcm_waitrequest;
assign msi_accept = rstn && state == MSI && !dcm_waitrequest;
assign fetch_accept = fetch_valid && fetch_ready;
assign diagnostic_accept = diagnostic_valid && diagnostic_ready;
// The queue entry ceases to be eligible BEFORE the receipt can be observed.
// RAM bits may remain, but rd_ptr/count no longer name that entry.
assign pop = (flag_accept && !active.do_msi) || msi_accept ||
             fetch_accept || diagnostic_accept;
assign published_success = pop && status_v2_success(active.word);
assign retired_ack_valid = rstn && state == RECEIPT;
assign retired_ack_word = active.word;
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    rd_ptr <= '0;
    wr_ptr <= '0;
    count <= '0;
    active <= '0;
    state <= IDLE;
    protocol_fault <= 1'b0;
    fault_word <= '0;
  end else begin
    case ({push, pop})
      2'b10: count <= count + 1'b1;
      2'b01: count <= count - 1'b1;
      default: ;
    endcase
    if (push) begin
      queue[wr_ptr].word <= s_word;
      queue[wr_ptr].base <= header_base;
      queue[wr_ptr].msi_address <= msi_interface[63:0];
      queue[wr_ptr].msi_data <= msi_interface[79:64];
      queue[wr_ptr].do_msi <= s_msi && msi_interface[80] && !s_word[7];
      wr_ptr <= next_ptr(wr_ptr);
    end
    if (pop) rd_ptr <= next_ptr(rd_ptr);
    // consumed is a receiver-owned level, never a credit for a future ACK.
    // A high outside the two receipt phases is a wiring/protocol error.
    if (retired_ack_consumed && state != RECEIPT && state != RETURN_LOW) begin
      protocol_fault <= 1'b1;
      fault_word <= active.word;
    end
    case (state)
      IDLE: begin
        if (protocol_fault || retired_ack_consumed) state <= BAD;
        else if (count != 0) begin
          active <= queue[rd_ptr];
          if (!status_v2_valid(queue[rd_ptr].word)) begin
            protocol_fault <= 1'b1;
            fault_word <= queue[rd_ptr].word;
            state <= BAD;
          end else if (queue[rd_ptr].word[7])
            state <= status_v2_success(queue[rd_ptr].word) ? FETCH : DIAGNOSTIC;
          else state <= FLAG;
        end
      end
      FLAG: if (flag_accept) begin
        if (active.do_msi) state <= MSI;
        else if (status_v2_success(active.word)) state <= RECEIPT;
        else begin active <= '0; state <= IDLE; end
      end
      MSI: if (msi_accept) begin
        if (status_v2_success(active.word)) state <= RECEIPT;
        else begin active <= '0; state <= IDLE; end
      end
      // The legacy controller consumer samples its ingress register on the
      // FETCH_FENCE edge. Receipt can only be accepted on a later edge.
      FETCH: if (fetch_accept) state <= FETCH_FENCE;
      FETCH_FENCE: state <= RECEIPT;
      DIAGNOSTIC: if (diagnostic_accept) begin active <= '0; state <= IDLE; end
      RECEIPT: if (retired_ack_consumed) begin
        active <= '0;
        state <= RETURN_LOW;
      end
      // Do not dispatch, replay, or issue a new receipt until the receiver
      // observes valid-low and returns its consumed level to low.
      RETURN_LOW: if (!retired_ack_consumed) state <= protocol_fault ? BAD : IDLE;
      BAD: state <= BAD;
      default: begin
        protocol_fault <= 1'b1;
        fault_word <= active.word;
        state <= BAD;
      end
    endcase
  end
end
// synthesis translate_off
initial if (DEPTH < 2) $fatal(1, "dma_status_sink_v3 DEPTH must be >=2");
assert property (@(posedge clk) disable iff (!rstn) count <= DEPTH);
assert property (@(posedge clk) disable iff (!rstn) pop |-> count != 0);
assert property (@(posedge clk) disable iff (!rstn)
  dcm_write && dcm_waitrequest |=>
    dcm_write && $stable({dcm_address,dcm_data,dcm_byteenable}));
assert property (@(posedge clk) disable iff (!rstn)
  fetch_valid && !fetch_ready |=> fetch_valid && $stable(fetch_word));
assert property (@(posedge clk) disable iff (!rstn)
  diagnostic_valid && !diagnostic_ready |=>
    diagnostic_valid && $stable(diagnostic_word));
assert property (@(posedge clk) disable iff (!rstn)
  retired_ack_valid |-> status_v2_success(retired_ack_word));
assert property (@(posedge clk) disable iff (!rstn)
  retired_ack_valid && !retired_ack_consumed |=>
    retired_ack_valid && $stable(retired_ack_word));
assert property (@(posedge clk) disable iff (!rstn)
  retired_ack_valid && retired_ack_consumed |=>
    !retired_ack_valid && state == RETURN_LOW && active == '0);
assert property (@(posedge clk) disable iff (!rstn)
  state == RETURN_LOW && retired_ack_consumed |=> state == RETURN_LOW);
assert property (@(posedge clk) disable iff (!rstn)
  $rose(retired_ack_valid) |->
    $past(published_success && !active.word[7]) ||
    $past(state == FETCH_FENCE));
assert property (@(posedge clk) disable iff (!rstn)
  state == FETCH_FENCE |-> $past(fetch_accept));
assert property (@(posedge clk) disable iff (!rstn)
  state == RECEIPT || state == RETURN_LOW |->
    !pop && !dcm_write && !fetch_valid && !diagnostic_valid);
// synthesis translate_on
endmodule
