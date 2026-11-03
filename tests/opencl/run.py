#!/usr/bin/env python3
"""Compile OpenCL kernel bodies for host arithmetic validation only."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build', type=Path, required=True)
parser.add_argument('--clang', default='clang')
parser.add_argument('--cxx', default='c++')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
build = args.build.resolve()
build.mkdir(parents=True, exist_ok=True)
subprocess.run([args.clang, '-x', 'cl', '-cl-std=CL1.2', '-O2', '-Wall', '-Wextra',
                '-Werror', '-c', str(root/'apps/opencl/correctness.cl'), '-o',
                str(build/'kernels.o')], check=True)
subprocess.run([args.cxx, '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
                '-I'+str(root/'include'), str(root/'tests/opencl/test_correctness.cpp'),
                str(build/'kernels.o'), '-o', str(build/'test')], check=True)
result = subprocess.run([str(build/'test')], text=True, capture_output=True, check=True)
(build/'native.log').write_text(result.stdout + result.stderr)
expected = [f'OPENCL_BODY_HOST_PASS count={n}' for n in (0,1,3,17,257,4093,65537,1000003)]
if result.stdout.splitlines() != expected:
    raise RuntimeError('Missing or unexpected host arithmetic result')
print(result.stdout, end='')
