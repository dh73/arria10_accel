"""Generate streaming testbench argument writes from compiler XML and CRA RTL.

The output is included inside streaming_kernel_execution_tb.launch. It performs
no device access and does not certify completion accounting or image identity.
"""
import argparse
import json
from pathlib import Path
from kernel_abi import extract, require

EXPRESSIONS = {
    'arg_count': "64'(count)", 'arg_dst': "64'(output_base)",
    'arg_src': "64'(first_input)", 'arg_a': "64'(first_input)",
    'arg_b': "64'(stride+64)", 'arg_scale': "64'd7",
}
EXPECTED = {
    'a10_streaming_Copy': {'arg_count':4, 'arg_dst':8, 'arg_src':8},
    'a10_streaming_Triad': {'arg_count':4, 'arg_dst':8, 'arg_a':8,
                            'arg_b':8, 'arg_scale':4},
}


UNROLLED_EXPECTED = {name.replace('a10_streaming_', 'a10_streaming_unrolled_'): args
                     for name, args in EXPECTED.items()}

MASKED_EXPECTED = {name.replace('a10_streaming_', 'a10_streaming_masked_'): args
                   for name, args in EXPECTED.items()}


def render(abi):
    names = {k['name'] for k in abi['kernels']}
    expected = next((contract for contract in
                     (EXPECTED, UNROLLED_EXPECTED, MASKED_EXPECTED)
                     if names == set(contract)), EXPECTED)
    require(names == set(expected),
            'expected copy and triad kernels')
    lines = ['case(base)']
    for kernel in abi['kernels']:
        require({a['name']: a['size'] for a in kernel['arguments']} == expected[kernel['name']],
                'streaming argument contract changed')
        lines.append(str(kernel['base'])+': begin')
        words = {}
        for arg in kernel['arguments']:
            for piece in arg['pieces']:
                offset = piece['byte_offset']
                terms, mask = words.setdefault(offset, ([], 0))
                terms.append('((('+EXPRESSIONS[arg['name']]+' >> '+str(piece['argument_bit_offset'])+
                             ") & 64'hffffffff) << "+str(piece['register_bit_offset'])+')')
                words[offset] = terms, mask | (15 << (piece['register_bit_offset']//8))
        for address, (terms, mask) in sorted(words.items()):
            lines.append(f"write_arg_csr(base+{address}, "+' | '.join(terms)+f", 8'h{mask:02x});")
        lines.append('end')
    lines += ['default: $fatal(1,"unknown generated kernel base");', 'endcase']
    return '\n'.join(lines)+'\n'


def prepare(source, output):
    abi = extract(source, packed=True)
    text = render(abi)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    (output/'stream_launch.svh').write_text(text)
    (output/'abi.json').write_text(json.dumps(abi, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    prepare(args.source, args.output)
