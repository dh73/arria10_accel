"""Encode source-derived kernel transactions for the PIO command mailbox.

No MMIO, driver discovery or execution authority. A transport must hold exclusive
mailbox ownership, fence posted writes, and complete each command before the
next. Unknown command acknowledgement forbids replay, including a repeated start.
"""
import argparse
import json
from pathlib import Path
from kernel_launch import encode as kernel_launch, unique_object
from kernel_abi import require


def transaction(base, target, *, value=None, mask=255):
    require(type(base) is int and 0 <= base <= (1 << 64)-32 and base % 4 == 0,
            'invalid mailbox aperture')
    require(type(target) is int and 0 <= target < 512 and target % 8 == 0,
            'invalid CRA target')
    writes = [(0, target)]
    if value is not None:
        require(type(value) is int and 0 <= value < 1 << 64, 'invalid CRA value')
        require(type(mask) is int and 0 < mask < 256, 'invalid CRA byte mask')
        writes += [(4, value & 0xffffffff), (8, value >> 32), (12, mask)]
    writes.append((16, 2 if value is None else 1))
    return {
        'write32': [{'byte_offset': base+a, 'data_le_hex': v.to_bytes(4, 'little').hex(),
                     'byte_enable': 15} for a, v in writes],
        'completion': {'status_byte_offset': base+20, 'busy_mask': 1,
                       'completed_value': 2, 'require_exact_status': True,
                       'posted_write_fence_required': True},
        'result_read32': [base+24, base+28] if value is None else [],
        'result_order': 'little-endian low then high',
        'replay_after_unknown_acknowledgement': False,
    }


def encode(source, name, arguments, base, *, packed=False):
    plan = kernel_launch(source, name, arguments, packed=packed)
    commands = [transaction(base, w['byte_offset'],
                            value=int.from_bytes(bytes.fromhex(w['data_le_hex']), 'little'),
                            mask=w['byte_enable']) for w in plan['writes']]
    return {'schema': 1, 'scope': 'source-derived mailbox commands; no hardware authority',
            'kernel': plan['kernel'], 'source_sha256': plan['source_sha256'],
            'commands': commands,
            'completion_read': transaction(base, plan['completion']['byte_offset']),
            'completion_contract': plan['completion'],
            'executor_requirements': plan['executor_requirements'] + [
                'Hold exclusive mailbox ownership across staging, command, completion and captured-result reads.',
                'Drain and fence each command before the next; do not combine or reorder operations.',
                'Never repeat an ambiguously acknowledged command or infer loaded-image compatibility from this packet.']}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('kernel')
    p.add_argument('arguments', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--mailbox-base', type=lambda x: int(x, 0), required=True)
    p.add_argument('--packed', action='store_true')
    a = p.parse_args()
    values = json.loads(a.arguments.read_text(), object_pairs_hook=unique_object)
    packet = encode(a.source, a.kernel, values, a.mailbox_base, packed=a.packed)
    with a.output.open('x') as out:
        out.write(json.dumps(packet, indent=2)+'\n')
