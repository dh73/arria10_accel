// SPDX-License-Identifier: BSD-3-Clause
module dma_status_sink_v2 #(
parameter int DEPTH = 16
) (
input  logic clk,
input  logic rstn,
input  logic s_valid,
output logic s_ready,
input  logic [31:0] s_word,
input  logic s_msi,
input  logic [63:0] header_base,
input  logic [81:0] msi_interface,
output logic dcm_write,
output logic [63:0] dcm_address,
output logic [31:0] dcm_data,
output logic [3:0] dcm_byteenable,
input  logic dcm_waitrequest,
output logic fetch_valid,
input  logic fetch_ready,
output logic [31:0] fetch_word,
output logic diagnostic_valid,
input  logic diagnostic_ready,
output logic [31:0] diagnostic_word,
output logic retired_ack_valid,
output logic [31:0] retired_ack_word,
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
typedef enum logic [2:0] {IDLE, FLAG, MSI, FETCH, DIAGNOSTIC, BAD} state_t;
entry_t queue [DEPTH];
entry_t active;
logic [PTR_W-1:0] rd_ptr, wr_ptr;
logic [COUNT_W-1:0] count;
state_t state;
logic push, pop, flag_accept, msi_accept, fetch_accept, diagnostic_accept;
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
assign flag_accept = state == FLAG && !dcm_waitrequest;
assign msi_accept = state == MSI && !dcm_waitrequest;
assign fetch_accept = fetch_valid && fetch_ready;
assign diagnostic_accept = diagnostic_valid && diagnostic_ready;
assign pop = (flag_accept && !active.do_msi) || msi_accept ||
fetch_accept || diagnostic_accept;
assign retired_ack_valid = rstn && pop && status_v2_success(active.word);
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
if (pop)
rd_ptr <= next_ptr(rd_ptr);
case (state)
IDLE: if (count != 0) begin
active <= queue[rd_ptr];
if (!status_v2_valid(queue[rd_ptr].word)) begin
protocol_fault <= 1'b1;
fault_word <= queue[rd_ptr].word;
state <= BAD;
end else if (queue[rd_ptr].word[7]) begin
state <= status_v2_success(queue[rd_ptr].word) ? FETCH : DIAGNOSTIC;
end else begin
state <= FLAG;
end
end
FLAG: if (flag_accept)
state <= active.do_msi ? MSI : IDLE;
MSI: if (msi_accept) state <= IDLE;
FETCH: if (fetch_accept) state <= IDLE;
DIAGNOSTIC: if (diagnostic_accept) state <= IDLE;
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
initial if (DEPTH < 2) $fatal(1, "dma_status_sink_v2 DEPTH must be >=2");
assert property (@(posedge clk) disable iff (!rstn) count <= DEPTH);
assert property (@(posedge clk) disable iff (!rstn)
pop |-> count != 0);
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
// synthesis translate_on
endmodule
