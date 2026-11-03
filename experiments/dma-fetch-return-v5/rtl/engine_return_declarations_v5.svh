// SPDX-License-Identifier: BSD-3-Clause
// Append metadata to the native queues; never recover a generation from a slot.
localparam int V5_META_W = 124;
typedef struct packed {
  logic [31:0] epoch;
  logic [19:0] token;
  logic [63:0] base;
  logic [7:0] count;
} v5_return_meta_t;
v5_return_meta_t v5_admit_meta, v5_current_meta;
v5_return_meta_t v5_tag_meta [16];
v5_return_meta_t v5_cpl_meta, v5_cmd_meta_pipe, v5_write_meta;
logic [63:0] v5_tag_source [16];
logic v5_session_fault, v5_guard_fault;
logic v5_bad_completion_shape;
logic v5_fault_q, v5_fault_now;
logic [31:0] v5_fault_epoch_q, v5_fault_epoch_now;
logic [19:0] v5_fault_token_q, v5_fault_token_now;
logic [7:0] v5_fault_reason_q, v5_fault_reason_now;
logic [7:0] v5_fault_tag_q, v5_fault_tag_now;
