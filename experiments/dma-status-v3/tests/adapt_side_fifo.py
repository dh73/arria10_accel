#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Derive a real read-engine/side-FIFO backpressure test; no other writers.

Uses the source-bound v3 adaptation, the application's one-cycle input stage,
and the unchanged external altpcie_fifo. This is not shell arbitration proof.
"""
from pathlib import Path
from adapt_v2_tests import adapt_engine, once


def adapt(path: Path) -> str:
    text = adapt_engine(path)
    text = once(text, 'module read_dma_candidate_v3_tb;',
                'module read_dma_side_fifo_v3_tb;')
    text = once(text, 'int target_count = 0, accepted_desc = 0, cycles = 0;',
                'int target_count = 0, accepted_desc = 0;')
    text = once(text, 'wire [259:0] tx;', '''int cycles = 0;
wire [259:0] tx, fifo_data;
logic staged_push = 0;
logic [259:0] staged_data = 0;
wire [4:0] occupancy;
logic drain_enabled = 0;
wire drain = drain_enabled && occupancy != 0 && cycles % 5 == 0;
int maximum_occupancy = 0, pushed = 0, popped = 0;
bit backpressure_checked = 0;
logic [259:0] expected_headers[$];
logic [259:0] expected_header;
altpcie_fifo #(.FIFO_DEPTH(16), .DATA_WIDTH(260)) side_fifo (
 .clk(clk), .rstn(rstn), .srst(1'b0), .wrreq(staged_push),
 .rdreq(drain), .data(staged_data), .q(fifo_data), .fifo_count(occupancy));
always @(posedge clk or negedge rstn) begin
 if (!rstn) begin staged_push <= 0; staged_data <= 0; end
 else begin staged_push <= tx_push; staged_data <= tx; end
end
always @(posedge clk) if (rstn) begin
 if ($isunknown(occupancy) || occupancy > 15)
   $fatal(1, "side FIFO count narrowed or unknown: %h", occupancy);
 if (occupancy > maximum_occupancy) maximum_occupancy = occupancy;
 if (tx_push) begin expected_headers.push_back(tx); pushed++; end
 if (drain) begin
   if (expected_headers.size() == 0) $fatal(1, "unexpected FIFO output");
   expected_header = expected_headers.pop_front();
   if (fifo_data !== expected_header) $fatal(1, "side FIFO header lost/reordered");
   popped++;
 end
end
initial begin : backpressure
 int held_pushed;
 wait (rstn && occupancy >= 14);
 // Finite stimulus hold, not a simulation execution deadline.
 repeat (8) @(negedge clk);
 held_pushed = pushed;
 repeat (8) @(negedge clk);
 if (pushed != held_pushed || occupancy < 14)
   $fatal(1, "read issuer did not settle under side FIFO backpressure");
 backpressure_checked = 1;
 drain_enabled = 1;
end''')
    text = once(text, '.TxFifoData_o(tx), .TxFifoCount_i(4\'b0),',
                '.TxFifoData_o(tx), .TxFifoCount_i(occupancy[3:0]),')
    # The completion generator sees only requests actually drained downstream.
    start = text.index('if (tx_push) begin\nif ($isunknown(tx)')
    end = text.index('if (held_write &&', start)
    block = text[start:end].replace('if (tx_push)', 'if (drain)')
    import re
    block = re.sub(r'\btx\b', 'fifo_data', block)
    text = text[:start] + block + text[end:]
    text = once(text, '$display("PASS candidate-v3 derived-v2', '''if (!backpressure_checked || pushed != popped || expected_headers.size() != 0 || occupancy != 0)
$fatal(1, "side FIFO coverage/drain incomplete");
$display("SIDE_FIFO pushed=%0d popped=%0d maximum_occupancy=%0d", pushed, popped, maximum_occupancy);
$display("PASS candidate-v3 derived-v2''')
    text = once(text, 'case (scenario)\n0:', '''if (scenario != 0 || ndesc != 8) $fatal(1, "side FIFO test requires SCENARIO=0 N=8");
case (scenario)
0:''')
    return text


if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    with a.output.open('x') as f:
        f.write(adapt(a.source))
