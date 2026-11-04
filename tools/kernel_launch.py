"""Encode a generated kernel launch; never performs MMIO or device discovery."""
import argparse
import json
import hashlib
import xml.etree.ElementTree as ET
from pathlib import Path

from kernel_abi import extract, require


def validate_buffer_alignment(source, abi, kernel_name, arguments):
    """Enforce compiler-declared pointer alignment from the same pinned XML."""
    xml_names = [n for n in abi['source_sha256'] if n.endswith('.bc.xml')]
    require(len(xml_names) == 1, 'expected one pinned argument XML')
    name = xml_names[0]
    data = (Path(source) / name).read_bytes()
    require(hashlib.sha256(data).hexdigest() == abi['source_sha256'][name],
            'argument XML changed during launch extraction')
    kernels = [k for k in ET.fromstring(data).iter('KERNEL') if k.get('kname') == kernel_name]
    require(len(kernels) == 1, 'ambiguous argument alignment kernel')
    required = {}
    for arg in kernels[0].iter('ARGUMENT'):
        if arg.get('opencl_type_category') != 'ACL_ARG_MEM_OBJ':
            continue
        name = arg.get('name')
        require(name not in required, 'duplicate pointer alignment')
        alignment = int(arg.get('alignment', '0'))
        require(0 < alignment <= 1 << 63 and alignment & (alignment-1) == 0,
                'invalid compiler buffer alignment: ' + name)
        value = arguments[name]
        require(type(value) is int and 0 <= value < 1 << (8*int(arg.get('size'))),
                'invalid buffer address: ' + name)
        require(value % alignment == 0, 'misaligned buffer address: ' + name)
        required[name] = alignment
    return required


def encode(source, kernel_name, arguments, *, packed=False):
    # Re-extract actual source rather than trusting a caller-modified manifest.
    abi = extract(source, packed=packed)
    kernels = [k for k in abi['kernels'] if k['name'] == kernel_name]
    require(len(kernels) == 1, 'unknown kernel')
    kernel = kernels[0]
    names = [a['name'] for a in kernel['arguments']]
    require(len(names) == len(set(names)), 'duplicate argument names')
    require(isinstance(arguments, dict) and set(arguments) == set(names),
            'arguments must contain exactly the generated names')
    alignments = validate_buffer_alignment(source, abi, kernel_name, arguments)
    writes = []
    if packed:
        from packed_kernel_args import encode as encode_packed
        writes = [{'byte_offset': w['address'],
                   'data_le_hex': w['value'].to_bytes(8, 'little').hex(),
                   'byte_enable': w['byteenable']} for w in encode_packed(kernel, arguments)]
    else:
        for arg in kernel['arguments']:
            value = arguments[arg['name']]
            require(type(value) is int and 0 <= value < (1 << 64),
                    'argument must be an unsigned 64-bit integer: ' + arg['name'])
            writes.append({'byte_offset': kernel['base'] + arg['byte_offset'],
                           'data_le_hex': value.to_bytes(8, 'little').hex(),
                           'byte_enable': 255})
    writes.append({'byte_offset': kernel['base'] + kernel['start_offset'],
                   'data_le_hex': '0100000000000000', 'byte_enable': 255})
    return {'schema': 2, 'kernel': kernel_name,
            'buffer_alignment_bytes': alignments,
            'scope': 'source-relative CSR writes; no hardware execution authority',
            'source_sha256': abi['source_sha256'],
            'cra_aperture_bytes': abi['cra_aperture_bytes'],
            'writes': writes,
            'completion': {'mode': 'read_clear_count',
                           'byte_offset': kernel['base'] + kernel['finish_count_offset'],
                           'width_bits': kernel['finish_count_bits'], 'expected': 1},
            'executor_requirements': [
                'Verify loaded shell identity and CRA mapping before access.',
                'Serialize against other launches and require kernel admission.',
                'Complete and order all argument writes before the final start write.',
                'Before admission, reconcile and consume prior completion counts; require no older launch pending.',
                'Consume exactly one finish count for this serialized launch; the sticky status bit alone is insufficient.',
                'Retain buffers until kernel and DMA retirement are established.']}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('kernel')
    parser.add_argument('arguments', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument("--packed", action="store_true", help="Trace packed 32/64-bit argument lanes from generated RTL")
    args = parser.parse_args()
    values = json.loads(args.arguments.read_text(), object_pairs_hook=unique_object)
    plan = encode(args.source, args.kernel, values, packed=args.packed)
    # Never overwrite an existing launch packet or an input file.
    with args.output.open('x') as output:
        output.write(json.dumps(plan, indent=2) + '\n')
