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


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    parser.add_argument('output',type=Path)
    args=parser.parse_args()
    args.output.write_text(json.dumps(extract(args.source),indent=2)+'\n')
