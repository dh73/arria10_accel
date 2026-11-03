#!/usr/bin/env python3
"""Derive a private D2H-head candidate; retain the exact mask candidate's FSMs.

Input is either the retained adapter or its exact mask-aware derivative.
Generated RTL is private and must not be added to the public repository.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

from build_control_wrapper import replace_once
from build_payload_mask import SOURCE_SHA, transform as add_mask

MASK_SHA = '399ac47d8137c3d175b30ffcf90cd405fd3d91edd0a6bb3c79f16ecb9200923d'

READ_CHECK = '''  // D2H enables index the aligned 32-byte response, not address-relative data.
  // Only native single-beat heads may have a nonzero DWORD offset. Aligned
  // commands retain the previous arbitrary command-mask semantics (also zero).
  function automatic logic bad_read_header(input logic [63:0] address,
                                           input logic [4:0] beats,
                                           input logic [31:0] mask);
    logic [63:0] beat_base;
    logic [64:0] end_exclusive;
    logic [31:0] below_start;
    beat_base={address[63:5],5'b0};
    end_exclusive={1'b0,beat_base}+({60'b0,beats}<<5);
    below_start=~(32'hffffffff << address[4:0]);
    return (address[1:0]!=0 || beats==0 || beats>16 ||
            end_exclusive>65'h080000000 ||
            (address[4:0]!=0 &&
             (beats!=1 || mask==0 || (mask & below_start)!=0)));
  endfunction
'''

ASSERTIONS = '''  // Accepted ownership retains the ORIGINAL diagnostic address. Normalize
  // only the backend beat, preserving the captured command mask and lane order.
  assert property (@(posedge pcie_clk) disable iff (!p_reset_n)
    wr_dma_read_o && !wr_dma_wait_request_i |=>
      base_q==$past(wr_dma_address_o) &&
      read_mask_q==$past(wr_dma_read_byte_enable_o) && !write_q);
  assert property (@(posedge user_clk) disable iff (!c_reset_n)
    cs!=C_IDLE && !c_write |-> !bad_read_header(c_base,c_count,c_read_mask));
  assert property (@(posedge user_clk) disable iff (!c_reset_n)
    cs!=C_IDLE && $past(cs)!=C_IDLE |->
      $stable({c_base,c_count,c_write,c_read_mask,c_ticket}));
  assert property (@(posedge user_clk) disable iff (!c_reset_n)
    avm_read |-> byte_address[4:0]==0 && byte_address<64'h80000000 &&
      avm_byteenable==({32'b0,c_read_mask} << (32*byte_address[5])));
'''


def mask_source(raw: bytes) -> str:
    digest = hashlib.sha256(raw).hexdigest()
    if digest == SOURCE_SHA:
        raw = add_mask(raw).encode('utf-8')
        digest = hashlib.sha256(raw).hexdigest()
    if digest != MASK_SHA:
        raise ValueError('Expected exact retained payload or mask candidate; SHA256=' + digest)
    return raw.decode('utf-8')


def transform(raw: bytes) -> str:
    s = mask_source(raw)
    changes = [
        ('module dma_payload_mask_candidate (',
         'module dma_payload_unaligned_candidate ('),
        ('  wire choose_write=rd_dma_write_o', READ_CHECK + '  wire choose_write=rd_dma_write_o'),
        ('  wire selected_bad=bad_header(selected_address,selected_count);',
         '  // H2D validation is deliberately unchanged; descriptor routing is external.\n'
         '  wire selected_bad=choose_write ? bad_header(selected_address,selected_count) :\n'
         '    bad_read_header(selected_address,selected_count,wr_dma_read_byte_enable_o);'),
        ("  wire [63:0] byte_address=c_base+({59'b0,c_index}<<5);",
         '  // Keep base_q/c_base raw for fault diagnostics. Do not shift mask or data.\n'
         "  wire [63:0] byte_address={c_base[63:5],5'b0}+({59'b0,c_index}<<5);"),
        ('`ifdef ARRIA10_ASSERTIONS\n', '`ifdef ARRIA10_ASSERTIONS\n' + ASSERTIONS),
    ]
    for old, new in changes:
        s = replace_once(s, old, new)
    return s


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    result = transform(a.source.read_bytes())  # reject before opening the output
    with a.output.open('x', encoding='utf-8', newline='\n') as f:
        f.write(result)


if __name__ == '__main__':
    main()
