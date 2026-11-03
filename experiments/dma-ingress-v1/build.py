#!/usr/bin/env python3
"""Derive the ready/valid-to-native-pulse application candidate from pinned input."""
import argparse
import hashlib
from pathlib import Path

SOURCE_SHA256 = 'f460c1163ab0a51b11be2168e9060e8d762ef2fdd811bf5d04f5e8602f01dfdc'
OLD_MODULE = b'module altpcieav_256_app_fetch_v4\n'
NEW_MODULE = b'module altpcieav_256_app_ingress_v1\n'
OLD_PORT = b'.WrDmaRxValid_i(AvWrDmaRxValid_i),'
NEW_PORT = b'.WrDmaRxValid_i(AvWrDmaRxValid_i && AvWrDmaRxReady_o),'


def transform(raw):
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError('application source identity mismatch')
    instance = b"   write_data_mover_2               ("
    for anchor in (OLD_MODULE, instance):
        if raw.count(anchor) != 1:
            raise ValueError('application anchor missing or ambiguous')
    start = raw.index(instance)
    end = raw.index(b");", start) + 2
    body = raw[start:end]
    if body.count(OLD_PORT) != 1:
        raise ValueError("native v2 valid connection missing or ambiguous")
    result = raw[:start] + body.replace(OLD_PORT, NEW_PORT) + raw[end:]
    return result.replace(OLD_MODULE, NEW_MODULE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    candidate = transform(args.source.read_bytes())
    # Never overwrite a retained candidate or mutate the original.
    with args.output.open('xb') as stream:
        stream.write(candidate)


if __name__ == '__main__':
    main()
