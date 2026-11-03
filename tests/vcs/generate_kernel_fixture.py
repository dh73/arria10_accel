"""Independent integer oracle for the initial 17-element generated-kernel test."""
from pathlib import Path
import argparse
parser = argparse.ArgumentParser()
parser.add_argument("--count", type=int, default=17)
parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent)
args = parser.parse_args()
assert 0 < args.count <= 1000003
args.output.mkdir(parents=True, exist_ok=True)
stride = ((args.count * 4 + 127) // 64) * 64

root = args.output
mask = 2**32 - 1

def rotate(value, count):
    return (value * 2**count) % 2**32 + value // 2**(32-count)

a, b, expected = [], [], []
for index in range(args.count):
    x = (0x6d2b79f5 + index * 0x1234567) & mask
    y = (0xa5a5a5a5 - index * 0x98765) & mask
    a.append(x)
    b.append(y)
    value = (x * 0x9e3779b1 + y + index * 0x85ebca6b) & mask
    value ^= x // 2**(index % 13 + 1)
    value = rotate(value, index % 31 + 1)
    value ^= value // 65536
    value = value * 0x7feb352d & mask
    value ^= value // 32768
    value = value * 0x846ca68b & mask
    value ^= value // 65536
    expected.append((value + rotate(y ^ index, 7)) & mask)

text = ''
for address, values in [(64, a), (stride+64, b)]:
    text += f'@{address:04x}\n'
    text += '\n'.join(f'{byte:02x}' for value in values
                      for byte in value.to_bytes(4, 'little')) + '\n'
(root/'kernel_execution_input.hex').write_text(text)
(root/'kernel_execution_expected.hex').write_text(
    '\n'.join(f'{value:08x}' for value in expected) + '\n')
