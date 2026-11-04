"""Cross-check generated memory-port dimensions; never certify hardware capacity."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


def extract(source):
    source = Path(source)
    files = {name: (source/name).read_bytes() for name in ('ipinterfaces.xml', 'kernel_system.sv')}
    xml = ET.fromstring(files['ipinterfaces.xml'])
    text = files['kernel_system.sv'].decode()
    # Inspect only the exported module header, not internal same-name wires.
    headers = re.findall(r'\bmodule\s+kernel_system\s*\((.*?)\);', text, re.S)
    if len(headers) != 1:
        raise ValueError('expected one kernel_system port header')
    header = re.sub(r'//[^\n]*|/\*.*?\*/', '', headers[0], flags=re.S)

    def port(name, direction):
        matches = re.findall(r'\b(input|output)\s+logic\s*(?:\[(\d+):0\]\s*)?'
                             + re.escape(name) + r'\s*(?:,|$)', header)
        if len(matches) != 1 or matches[0][0] != direction:
            raise ValueError('missing/ambiguous/direction-mismatched port: '+name)
        return int(matches[0][1])+1 if matches[0][1] else 1

    memories = []
    names = set()
    for memory in xml.findall('global_mem'):
        for interface in memory.findall('interface'):
            name = interface.get('port', '')
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', name) or name in names:
                raise ValueError('invalid/duplicate memory port')
            names.add(name)
            if interface.get('type') != 'agent':
                raise ValueError('unsupported memory interface type')
            width = int(interface.get('width', '0'))
            address = int(interface.get('address', '-1'), 0)
            size = int(interface.get('size', '0'), 0)
            if width <= 0 or width % 8 or address < 0 or size <= 0:
                raise ValueError('invalid memory dimensions')
            for suffix, direction, expected in [('writedata','output',width),
                    ('readdata','input',width),('byteenable','output',width//8),
                    ('read','output',1),('write','output',1),('waitrequest','input',1),
                    ('readdatavalid','input',1),('writeack','input',1)]:
                if port(name+'_'+suffix,direction) != expected:
                    raise ValueError('XML/RTL width mismatch: '+suffix)
            address_bits = port(name+'_address','output')
            burst_bits = port(name+'_burstcount','output')
            memories.append(dict(port=name,data_bits=width,byteenable_bits=width//8,
                address_bits=address_bits,burstcount_bits=burst_bits,
                model_base=address,model_size=size,
                address_units='not established by this dimension check',
                physical_capacity_verified=False))
    if not memories:
        raise ValueError('no memory interfaces')
    return dict(schema=1,scope='generated XML/RTL dimensions only',memories=memories,
        source_sha256={name:hashlib.sha256(data).hexdigest() for name,data in files.items()},
        physical_acceptance=False)


# Source-audited OpenCL chain: kernel_system forwards mem0_rw unchanged;
# streaming_di configures AWIDTH41/MWIDTH_BYTES8 and forwards the interconnect;
# lsu_ic_top reconstructs byte addresses by appending LOG2BYTES zero bits.
# This binds units only, not capacity, semantics of arbitrary future generators,
# physical compatibility or peak bandwidth.
OPENCL_BYTE_ADDRESS_SHA256 = {'ipinterfaces.xml': '1d393f74b0d3b22fc6ff7cda08babf334f1fddf1d1f3b83751ca3658f4bace9c',
 'kernel_system.sv': '67277c71492551efa9bf31b23184115ccfff247b5fc8cba3804a481d420ff033',
 'streaming_di.sv': '2a1982a5f663794a371cc5310d11829d4b406ee1a177520a5072d68d2fcbd414',
 'ip/lsu_ic_top.sv': '0055b4e37914420969b45d4bb0db294e6d593c6a2f58a5956cf0167410f6be96'}


def qualify_opencl_byte_addresses(source, report):
    source = Path(source)
    for name, expected in OPENCL_BYTE_ADDRESS_SHA256.items():
        if hashlib.sha256((source/name).read_bytes()).hexdigest() != expected:
            raise ValueError('unqualified OpenCL address-chain source: '+name)
    # Re-extract so a caller-supplied dimension report cannot confer a profile.
    exact = extract(source)
    if exact != report or len(exact['memories']) != 1:
        raise ValueError('address profile requires exact source dimension report')
    memory = exact['memories'][0]
    if (memory['port'],memory['data_bits'],memory['address_bits']) != ('mem0_rw',64,41):
        raise ValueError('address profile dimensions changed')
    memory['address_units'] = 'bytes'
    exact['scope'] = 'generated dimensions and exact source-bound byte-address chain'
    exact['address_profile'] = 'opencl_stream_byte_address_v1'
    exact['source_sha256'].update(OPENCL_BYTE_ADDRESS_SHA256)
    return exact


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    parser.add_argument('output',type=Path)
    parser.add_argument('--opencl-byte-address-profile',action='store_true')
    args=parser.parse_args()
    report=extract(args.source)
    if args.opencl_byte_address_profile:
        report=qualify_opencl_byte_addresses(args.source,report)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
