// SPDX-License-Identifier: BSD-3-Clause
logic [3:0] v2_alloc_slot, v2_head_slot, v2_current_slot;
logic [3:0] v2_tag_owner[16];
logic [15:0] v2_tag_live, v2_last_header, v2_halted;
logic [3:0] v2_cpl_slot, v2_cmd_slot_pipe, v2_write_slot;
logic v2_current_valid, v2_start, v2_close, v2_head_drop;
logic v2_control_load, v2_stop_issue, v2_master_error, v2_desc_ready;
logic v2_bad_header, v2_guard_fault, v2_external_fault;
logic v2_cmd_start;
