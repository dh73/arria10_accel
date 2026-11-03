#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Derive v3 integration TBs from explicit, read-only v2 test inputs.

The 37-case v2 suite is not rewritten. These two copies retain its 32 engine
cases and three actual-engine/controller error cases, with a finite four-phase
receipt producer and connected reverse path. Different inputs fail closed.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

ENGINE_SHA256 = "41afda506f3553d9c36b1a09422a8f1f0bb2f0584b54a54556d906fb13a44f74"
CONTROLLER_SHA256 = "a3ba7104819d3cc563f48e67e36b6539e351487854bebfc27483ac40104f7941"


def source(path: Path, digest: str) -> str:
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != digest:
        raise ValueError(f"{path}: expected original v2 test SHA256 {digest}; "
                         "supply/review the changed test source before deriving v3")
    return raw.decode("utf-8")


def once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise ValueError(f"test anchor must occur once, found {count}: {old[:100]!r}")
    return text.replace(old, new, 1)


def adapt_engine(path: Path) -> str:
    text = source(path, ENGINE_SHA256)
    text = once(text, "module read_dma_candidate_v2_tb;", "module read_dma_candidate_v3_tb;")
    text = once(text, "altpcieav_dma_rd_candidate_v2 #(", "altpcieav_dma_rd_candidate_v3 #(")
    text = once(text, "logic ack_valid = 0;", "logic ack_valid = 0;\nlogic ack_returning = 0;\nwire ack_consumed;")
    text = once(text, ".RdDmaAckData_i(ack_data), .RdDMACntrlReady_o(ctrl_ready),",
                ".RdDmaAckData_i(ack_data), .RdDmaAckConsumed_o(ack_consumed),\n.RdDMACntrlReady_o(ctrl_ready),")
    text = once(text, 'if (cycles > 200000) $fatal(1, "watchdog scenario=%0d requests=%0d beats=%0d statuses=%0d", scenario, requests, accepted, statuses);\n', "")
    text = once(text, "ack_valid <= 0;\nack_data <= 0;", "ack_valid <= 0;\nack_returning <= 0;\nack_data <= 0;")
    text = once(text, "ack_valid <= 0;\nif (desc_valid && !ready)", """// Model one local receipt producer; held high is the SAME receipt.
if (ack_valid && ack_consumed) begin
  ack_valid <= 0;
  ack_returning <= 1;
  ack_data <= 0;
end
if (ack_returning && !ack_consumed) ack_returning <= 0;
if (desc_valid && !ready)""")
    text = once(text, "ack_valid <= 1;\nack_data <= status_data;", """if (ack_valid || ack_returning || ack_consumed)
  $fatal(1, "v3 status overtook an unclosed success receipt");
ack_valid <= 1;
ack_data <= status_data;""")
    text = once(text, "terminal_statuses != terminals || ack_valid || held_status || in_burst != 0",
                "terminal_statuses != terminals || ack_valid || ack_returning || ack_consumed || held_status || in_burst != 0")
    return text.replace("PASS candidate-v2", "PASS candidate-v3 derived-v2")


def adapt_controller(path: Path) -> str:
    text = source(path, CONTROLLER_SHA256)
    text = once(text, "module read_dma_controller_v2_tb;", "module read_dma_controller_v3_tb;")
    text = once(text, "altpcieav_dma_rd_candidate_v2 #(", "altpcieav_dma_rd_candidate_v3 #(")
    text = once(text, "altpcie_dynamic_control_candidate_v2 controller (", "altpcie_dynamic_control_candidate_v3 controller (")
    text = once(text, "wire ack_valid, engine_fault, controller_fault;", "wire ack_valid, ack_consumed, engine_fault, controller_fault;")
    text = once(text, ".RdDmaAckData_i(ack_data),", ".RdDmaAckData_i(ack_data), .RdDmaAckConsumed_o(ack_consumed),")
    text = once(text, ".DmaAckData_o(ack_data),", ".DmaAckData_o(ack_data), .DmaAckConsumed_i(ack_consumed),")
    text = once(text, 'if (cycles > 20000) $fatal(1, "controller integration watchdog");\n', "")
    text = once(text, "if (ack_valid) $fatal", "if (ack_valid || ack_consumed) $fatal")
    return text.replace("PASS actual engine/controller candidate-v2", "PASS actual engine/controller candidate-v3 derived-v2")
