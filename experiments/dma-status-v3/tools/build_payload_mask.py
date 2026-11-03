#!/usr/bin/env python3
"""Add accepted read-mask custody to an exact retained payload adapter."""
import argparse
import hashlib
from pathlib import Path
from build_control_wrapper import replace_once

SOURCE_SHA = 'a7a66662e3d15497cf24ade5ce672733104eadbeb670175b542adab6c409c06c'


def transform(source):
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA:
        raise ValueError('Expected exact retained payload adapter')
    s = source.decode()
    changes = [
        ('module arria10_dma_payload (', 'module dma_payload_mask_candidate ('),
        ('  input logic wr_dma_read_o,',
         '  input logic wr_dma_read_o,\n  input logic [31:0] wr_dma_read_byte_enable_o,'),
        ('  logic [63:0] base_q, c_base;',
         '  logic [63:0] base_q, c_base;\n  logic [31:0] read_mask_q, c_read_mask;'),
        ('      req_toggle<=0; write_q<=0; base_q<=0; count_q<=0;',
         '      req_toggle<=0; write_q<=0; base_q<=0; count_q<=0; read_mask_q<=0;'),
        ('            base_q<=selected_address; count_q<=selected_count;',
         '            base_q<=selected_address; count_q<=selected_count;\n'
         '            read_mask_q<=wr_dma_read_byte_enable_o;'),
        ("    avm_writedata='0; avm_byteenable='1;",
         "    avm_writedata='0; avm_byteenable='0;\n"
         '    avm_byteenable[32*byte_address[5]+:32]=c_read_mask;'),
        ('      done_toggle<=0; c_ticket<=0; c_write<=0; c_base<=0; c_count<=0; c_index<=0;',
         '      done_toggle<=0; c_ticket<=0; c_write<=0; c_base<=0; c_count<=0; c_index<=0; c_read_mask<=0;'),
        ('          c_write<=write_q; c_index<=0; c_error<=0; cs<=C_ISSUE;',
         '          c_write<=write_q; c_read_mask<=read_mask_q; c_index<=0; c_error<=0; cs<=C_ISSUE;'),
        ('$stable({base_q,count_q,write_q,req_toggle})',
         '$stable({base_q,count_q,write_q,read_mask_q,req_toggle})'),
    ]
    for before, after in changes:
        s = replace_once(s, before, after)
    return s


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    with a.output.open('x') as f:
        f.write(transform(a.source.read_bytes()))
