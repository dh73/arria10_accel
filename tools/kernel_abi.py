"""Extract this compiler's CSR ABI from XML AND generated RTL; no device access.

Fail closed on unsupported generator shapes instead of assuming an ABI version.
This is a source contract, not evidence that a loaded FPGA image matches it.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

# Exact corrected scalar/vector CRA bodies qualified by native counter tests.
# Vector qualification: qualification/kernel-launch-custody-v1/corrected2.
# This identifies source accounting only, never a device/transport capability.
SNAPSHOT_RETIREMENT_SHA256 = {
    'stream_copy512': '69a0e196e0137b7c83232178cde4d0a40e294c6f87bfcff8b452e4ab6ebb6407',
    'stream_triad512': 'b68329a2df74165713acb080692e2bfcbceed411242bfe8b88283a04698183ea',
    'a10_streaming_Copy': '813cfa3c23f5dd12153a739d797ed6269cb0d011399e1dee2200fb11b1af7d28',
    'a10_streaming_Triad': '99945ded8689c9fea99e3208fc87df774e95a50f3073951d428d1c510e31e30d',
    'Pass1Kernel': '3f62ef3954e2d15b28752c02ab7780fa1c740ce7554e068269b81f811e6b6ff4',
    'Pass2Kernel': 'ea1a3728cf7ac66bbcc5765eb658f184d8c71bd18f740571ae8ccea91fd2c7f2',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def one(pattern, text):
    matches = re.findall(pattern, text, re.S)
    require(len(matches) == 1, 'unsupported/ambiguous RTL pattern: ' + pattern)
    return matches[0]


def extract(source, *, packed=False):
    source = Path(source).resolve()
    hashes = {}

    def read(relative):
        path = (source / relative).resolve()
        require(path.is_relative_to(source), 'source path escapes snapshot')
        data = path.read_bytes()
        hashes[relative] = hashlib.sha256(data).hexdigest()
        return data.decode()

    xml_files = list(source.glob('*.bc.xml'))
    require(len(xml_files) == 1, 'expected one compiler kernel XML')
    xml = ET.fromstring(read(xml_files[0].name))
    top = read('kernel_system.sv')
    require('assign sys_cra_ring_address = kernel_cra_address >> 3;' in top,
            'unsupported CRA byte-to-word address conversion')
    width = int(one(r'logic\s+\[(\d+):0\]\s+sys_cra_ring_address;', top)) + 1
    aperture = (1 << width) * 8
    result = []
    names = set()
    for kernel in xml.iter('KERNEL'):
        name = kernel.get('kname')
        require(name and name not in names, 'duplicate/missing kernel name')
        names.add(name)
        interfaces = [i for i in kernel.iter('INTERFACE') if i.get('port') == 'cra']
        require(len(interfaces) == 1, 'ambiguous CRA interface')
        interface = interfaces[0]
        require(interface.get('width') == '64' and interface.get('type') == 'agent',
                'unsupported CRA width/type')
        base, size = int(interface.get('base_address')), int(interface.get('size'))
        require(base >= 0 and base % 8 == 0 and size > 0 and size % 8 == 0 and
                base + size <= aperture, 'CRA window outside non-aliasing aperture')
        wrapper = read(kernel.get('filename'))
        agent_name = interface.get('cosim_name')
        require(re.fullmatch(r'[A-Za-z0-9_]+', agent_name or ''), 'invalid CSR agent name')
        agent_path = str(Path(kernel.get('filename')).parent / (agent_name + '.sv'))
        agent = read(agent_path)
        corrected = hashes[agent_path] == SNAPSHOT_RETIREMENT_SHA256.get(name)

        def constant(name):
            bits = one(r'assign\s+'+re.escape(name)+r"\s*=\s*\d+'b([01]+);", agent)
            return int(bits, 2)

        start = constant('Start_address_ref_q') * 8
        status = constant('Status_address_ref_q') * 8
        finish_count = constant('finish_counter_addr_q') * 8
        require('assign clear_finish_counter_pre_comp_q = is_finish_counter_addr_q & avs_cra_read;' in agent and
                (corrected or 'assign padded_finish_counter_q = {const_finish_counter_padding_q, finish_counter_NO_SHIFT_REG_q};' in agent) and
                re.search(r'reg\s+\[1:0\]\s+finish_counter_NO_SHIFT_REG_q;', agent),
                'unsupported finish counter read/clear shape')
        require(corrected or 'read_clear_safe_' not in agent,
                'unqualified modified CRA accounting body')
        require(finish_count not in (start, status) and finish_count + 8 <= size,
                'invalid completion counter offset')
        require(start != status and max(start, status) + 8 <= size, 'invalid control offsets')
        require(re.search(r'assign status_self_update_q = \{[^;]*compute_finished_q, start_bit_computation_q\};', agent),
                'unsupported finished-bit packing')
        args = []
        offsets = set([start, status, finish_count])
        if packed:
            from packed_kernel_args import extract_arguments
            args = extract_arguments(kernel, wrapper, agent, constant, size, offsets, one, require)
        else:
            for index, arg in enumerate(kernel.iter('ARGUMENT')):
                arg_name = arg.get('name')
                require(re.fullmatch(r'[A-Za-z0-9_]+', arg_name or ''), 'invalid argument name')
                require(arg.get('size') == '8' and arg.get('is_streaming') == 'false',
                        'unsupported argument size/streaming')
                high, low = one(r'assign\s+arg_'+re.escape(arg_name)+r'_select_b\s*=\s*kernel_arguments\[(\d+):(\d+)\];', wrapper)
                require(int(low) == index * 64 and int(high) == index * 64 + 63,
                        'XML/RTL argument order mismatch')
                # Trace the actual register write enable through comparator to address.
                half_offsets = []
                for half in (0, 1):
                    enable = one(r'// arguments_'+str(2*index+half)+r"_buffered\(REG.*?else if \((\w+) == 1'b1\)", agent)
                    compare = one(r'assign\s+'+re.escape(enable)+r'\s*=\s*(\w+) & avs_cra_write;', agent)
                    address_ref = one(r'assign\s+'+re.escape(compare)+r"\s*=\s*\$unsigned\(avs_cra_address == (\w+) \? 1'b1 : 1'b0\);", agent)
                    half_offsets.append(constant(address_ref) * 8)
                require(half_offsets[0] == half_offsets[1], "argument halves use different registers")
                offset = half_offsets[0]
                require(offset not in offsets and offset + 8 <= size, 'overlapping/out-of-range argument')
                offsets.add(offset)
                args.append({'name':arg_name, 'byte_offset':offset, 'size':8,
                             'kind':arg.get('opencl_type_category'), 'rtl_bit_offset':int(low)})
        result.append({'name':name,'base':base,'size':size,'start_offset':start,
                       'status_offset':status,'finished_bit':1,
                       'finish_count_offset':finish_count,'finish_count_bits':2,
                       'finish_count_clear_on_read':True,'arguments':args})
        if corrected:
            result[-1]['completion_accounting'] = 'delayed_snapshot_v1'
    require(result, 'no kernels')
    ordered = sorted(result, key=lambda k:k['base'])
    for previous, current in zip(ordered, ordered[1:]):
        require(previous['base'] + previous['size'] <= current['base'], 'overlapping kernel windows')
    return {'schema':2 if packed else 1,'scope':'generated source only; loaded image not verified',
            'cra_aperture_bytes':aperture,'kernels':result,'source_sha256':hashes}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(extract(args.source), indent=2)+'\n')
