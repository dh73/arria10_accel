#!/usr/bin/env python3
"""Widen the retained D2H producer's offset-plus-length intermediate.

This isolated derivative preserves descriptor width, pipeline stages and the
16-bit completion-count FIFO. It does not qualify full producer behavior.
"""
import argparse
import hashlib
from pathlib import Path

SOURCE_SHA = '9658fce313dc40ea278021747923137a9cad5fc3df344ecc6818e63e010aef54'


def transform(raw: bytes) -> bytes:
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA:
        raise ValueError('Expected exact retained D2H producer source')
    replacements = (
        (b'logic [17:0]                    adjusted_dw;',
         b'logic [18:0]                    adjusted_dw;'),
        (b'logic [17:0]                    adjusted_dw_reg;',
         b'logic [18:0]                    adjusted_dw_reg;'),
    )
    for before, after in replacements:
        if raw.count(before) != 1:
            raise ValueError('Ambiguous intermediate declaration')
        raw = raw.replace(before, after, 1)
    if raw.count(b'adjusted_dw_reg[17:3]') != 2:
        raise ValueError('Unexpected completion count equation')
    return raw.replace(b'adjusted_dw_reg[17:3]', b'adjusted_dw_reg[18:3]')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    corrected = transform(a.source.read_bytes())
    with a.output.open('xb') as f:
        f.write(corrected)


if __name__ == '__main__':
    main()
