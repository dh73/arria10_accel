# SPDX-License-Identifier: BSD-3-Clause
"""Retain descriptor execution order within each fetched table destination.

The v5 consumer round-robins committed banks after each emitted descriptor.
That preserves each bank's own ordinal but can reorder one controller's FIFO:
two committed read tables [0,1] and [2,3] can emit [0,2,1,3]. A later complete
table can also bypass an earlier incomplete table. Real DCS doorbells name a
descriptor sequence, so per-bank order is insufficient at this composition.

This derivative queues bank identities at the actual issue handshake, separately
for the two table destinations. Only a destination's head bank may emit. Its
head advances on the accepted final copier beat; receipt and bank release keep
their original independent rules. The other destination remains eligible.
An errored head is retained: there is no invented cancellation/fence contract.

Only the exact regenerated v5 consumer is accepted. Every unrelated generated
file and all unmodified consumer regions are retained byte-for-byte. The
public patch contains owned transformations, not licensed source bodies.
"""
from __future__ import annotations

import hashlib


CONSUMER_NAME = "dma_fetch_commit_return_v5.sv"
CONSUMER_SHA256 = "b45a59a83840e6910e17d81b434110d749b22506cec160b9cd07286406a0b634"


def once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise ValueError(f"composition order anchor is not unique: {old[:90]!r}")
    return source.replace(old, new, 1)


ORDER_DECLARATIONS = """
  // One issue-order queue per destination. Entries name already reserved banks;
  // capacity is the existing BANKS resource, not a new lifetime/traffic limit.
  localparam int ORDER_CW = $clog2(BANKS+1);
  bank_t order_bank [2][BANKS];
  bank_t order_rd [2], order_wr [2];
  wire [BW-1:0] order_head [2];
  logic [ORDER_CW-1:0] order_count [2];
  logic order_turn;
  wire order_last = emit_valid && emit_ready &&
    ({1'b0,drained[emit_bank]}+9'd1)=={1'b0,needed[emit_bank]};
  wire [1:0] order_push = {fire_issue && issue_desc[152],
                          fire_issue && !issue_desc[152]};
  wire [1:0] order_pop = {order_last && emit_write_table,
                         order_last && !emit_write_table};
  function automatic bank_t order_next(input bank_t pointer);
    return pointer==bank_t'(BANKS-1) ? '0 : pointer+1'b1;
  endfunction
  for (genvar destination=0;destination<2;destination++) begin: order_heads
    assign order_head[destination] = order_bank[destination][order_rd[destination]];
  end
"""

ORDER_STATE = """
  // The queue is changed only by the same physical handshakes already used by
  // the consumer. A simultaneous issue and final copy preserves the count.
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      order_turn<=0;
      for (int d=0;d<2;d++) begin
        order_rd[d]<='0; order_wr[d]<='0; order_count[d]<='0;
        for (int k=0;k<BANKS;k++) order_bank[d][k]<='0;
      end
    end else begin
      if (emit_valid && emit_ready) order_turn<=!emit_write_table;
      for (int d=0;d<2;d++) begin
        case ({order_push[d],order_pop[d]})
          2'b10: order_count[d]<=order_count[d]+1'b1;
          2'b01: order_count[d]<=order_count[d]-1'b1;
          default: ;
        endcase
        if (order_push[d]) begin
          order_bank[d][order_wr[d]]<=bank_t'(free_bank);
          order_wr[d]<=order_next(order_wr[d]);
        end
        if (order_pop[d]) order_rd[d]<=order_next(order_rd[d]);
      end
    end
  end
  // synthesis translate_off
  assert property (@(posedge clk) disable iff(!rstn)
    int'(order_count[0])+int'(order_count[1])<=BANKS);
  assert property (@(posedge clk) disable iff(!rstn)
    emit_valid |-> order_count[emit_write_table]!=0 &&
      emit_bank==order_head[emit_write_table]);
  for (genvar d=0;d<2;d++) begin: ordered_destination_assertions
    assert property (@(posedge clk) disable iff(!rstn)
      order_push[d] |-> int'(order_count[d])<BANKS && free_bank>=0 && !live[free_bank]);
    assert property (@(posedge clk) disable iff(!rstn)
      order_pop[d] |-> order_count[d]!=0 && emit_bank==order_head[d] &&
        emit_write_table==d && committed[emit_bank]);
    assert property (@(posedge clk) disable iff(!rstn)
      order_count[d]!=0 |-> live[order_head[d]] && issued[order_head[d]][152]==d);
    assert property (@(posedge clk) disable iff(!rstn)
      $changed(order_rd[d]) |-> $past(order_pop[d]));
    assert property (@(posedge clk) disable iff(!rstn)
      $past(rstn) && $past(order_push[d] && !order_pop[d]) |->
        order_count[d]==$past(order_count[d])+1'b1);
    assert property (@(posedge clk) disable iff(!rstn)
      $past(rstn) && $past(order_pop[d] && !order_push[d]) |->
        order_count[d]+1'b1==$past(order_count[d]));
  end
  // synthesis translate_on
"""

OLD_PICKER = """        for (int j=0;j<BANKS;j++)
          if (pick<0 && live[(int'(cursor)+j)%BANKS] &&
              committed[(int'(cursor)+j)%BANKS] &&
              drained[(int'(cursor)+j)%BANKS]<needed[(int'(cursor)+j)%BANKS])
            pick=(int'(cursor)+j)%BANKS;
"""

NEW_PICKER = """        // Fairness is between destinations, never between two tables
        // targeting the same executable FIFO. An incomplete/failed head
        // retains that destination even if a later table has committed.
        for (int j=0;j<2;j++)
          if (pick<0 && order_count[(int'(order_turn)+j)%2]!=0 &&
              live[order_head[(int'(order_turn)+j)%2]] &&
              committed[order_head[(int'(order_turn)+j)%2]] &&
              drained[order_head[(int'(order_turn)+j)%2]]<
                needed[order_head[(int'(order_turn)+j)%2]])
            pick=int'(order_head[(int'(order_turn)+j)%2]);
"""


def repair_consumer(source: str) -> str:
    if hashlib.sha256(source.encode("utf-8")).hexdigest() != CONSUMER_SHA256:
        raise ValueError("composition order repair requires the exact pinned v5 consumer")
    source = once(source,
                  "logic [BW-1:0] emit_bank, cursor, diag_bank, local_bank, receipt_bank;",
                  "logic [BW-1:0] emit_bank, diag_bank, local_bank, receipt_bank;")
    source = once(source,
                  "  assign status_token = {status_word[23:16],status_word[15:12],status_word[7:0]};",
                  ORDER_DECLARATIONS +
                  "  assign status_token = {status_word[23:16],status_word[15:12],status_word[7:0]};")
    source = once(source, "emit_bank<='0; cursor<='0;", "emit_bank<='0;")
    source = once(source,
                  "          cursor<=emit_bank==bank_t'(BANKS-1) ? '0 : emit_bank+1'b1;\n", "")
    source = once(source, OLD_PICKER, NEW_PICKER)
    source = once(source, "  // synthesis translate_off\n  initial if (BANKS<1 || BANKS>16)",
                  ORDER_STATE + "\n  // synthesis translate_off\n  initial if (BANKS<1 || BANKS>16)")
    return source


def derive(generated: dict[str, str]) -> dict[str, str]:
    """Return a new dictionary; leave the input and unrelated bytes untouched."""
    if CONSUMER_NAME not in generated:
        raise ValueError(f"composition source set lacks {CONSUMER_NAME}")
    result = dict(generated)
    result[CONSUMER_NAME] = repair_consumer(generated[CONSUMER_NAME])
    return result
