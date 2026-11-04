"""Trace packed 32/64-bit argument writes through generated CRA RTL."""
import re


def extract_arguments(kernel, wrapper, agent, constant, size, reserved, one, require):
    args, occupied, bit = [], set(), 0
    names = set()
    for arg in kernel.iter('ARGUMENT'):
        name = arg.get('name')
        require(re.fullmatch(r'[A-Za-z0-9_]+', name or '') and name not in names,
                'invalid/duplicate argument name')
        names.add(name)
        n = int(arg.get('size', '0'))
        require(n in (4, 8) and arg.get('is_streaming') == 'false', 'unsupported packed argument')
        kind = arg.get('opencl_type_category')
        require(kind in ('ACL_ARG_BY_VALUE', 'ACL_ARG_MEM_OBJ'), 'unsupported argument kind')
        require(kind != 'ACL_ARG_MEM_OBJ' or n == 8, 'unsupported pointer width')
        high, low = map(int, one(r'assign\s+arg_'+re.escape(name)+r'_select_b\s*=\s*kernel_arguments\[(\d+):(\d+)\];', wrapper))
        require(low == bit and high == bit + n*8-1, 'XML/RTL packed argument order mismatch')
        pieces = []
        for offset in range(0, n, 4):
            index = bit//32 + offset//4
            slot = 'arguments_'+str(index)+'_buffered_q'
            enable, data = one(r'// arguments_'+str(index)+r"_buffered\(REG.*?else if \((\w+) == 1'b1\)\s*begin\s*"+slot+r' <= (\w+);', agent)
            compare = one(r'assign\s+'+enable+r'\s*=\s*(\w+) & avs_cra_write;', agent)
            ref = one(r'assign\s+'+compare+r"\s*=\s*\$unsigned\(avs_cra_address == (\w+) \? 1'b1 : 1'b0\);", agent)
            address = constant(ref)*8
            hold, update = one(r'assign\s+'+data+r'\s*=\s*(\w+) \| (\w+);', agent)
            mask, bus = one(r'assign\s+'+update+r'\s*=\s*(\w+) & (\w+);', agent)
            hi, lo = map(int, one(r'assign\s+'+bus+r'\s*=\s*avs_cra_writedata\[(\d+):(\d+)\];', agent))
            require((hi, lo) in ((31, 0), (63, 32)), 'unsupported write lane')
            require(re.search(r'assign\s+'+mask+r'\s*=\s*bit_enable_q\['+str(hi)+':'+str(lo)+r'\];', agent), 'write mask lane mismatch')
            oldmask = one(r'assign\s+'+hold+r'\s*=\s*(\w+) & '+slot+r';', agent)
            require(re.search(r'assign\s+'+oldmask+r'\s*=\s*bit_enable_bar_q\['+str(hi)+':'+str(lo)+r'\];', agent), 'preservation mask lane mismatch')
            require(address not in reserved and address+8 <= size, 'reserved/out-of-range packed register')
            require((address, lo) not in occupied, 'overlapping packed argument')
            occupied.add((address, lo))
            pieces.append(dict(byte_offset=address, register_bit_offset=lo, argument_bit_offset=offset*8, bits=32))
        args.append(dict(name=name, size=n, kind=arg.get('opencl_type_category'), rtl_bit_offset=bit, pieces=pieces))
        bit += n*8
    return args


def encode(kernel, values):
    if set(values) != {a['name'] for a in kernel['arguments']}:
        raise ValueError('exact argument names required')
    words = {}
    for arg in kernel['arguments']:
        value = values[arg['name']]
        if type(value) is not int or not 0 <= value < 1 << (8*arg['size']):
            raise ValueError('argument out of range')
        for piece in arg['pieces']:
            address = kernel['base']+piece['byte_offset']
            data, mask = words.get(address, (0, 0))
            shift = piece['register_bit_offset']
            data |= ((value >> piece['argument_bit_offset']) & 0xffffffff) << shift
            mask |= 0xf << (shift//8)
            words[address] = data, mask
    return [dict(address=a, value=d, byteenable=m) for a, (d,m) in sorted(words.items())]
