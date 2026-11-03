# OpenCL correctness kernels

`correctness.cl` implements the same two-pass modular integer workload as the
SYCL application. Each kernel is a single work item with a sequential loop.
Allocate disjoint input, intermediate and output buffers of `count` 32-bit
unsigned elements. Set the four arguments in declaration order. Enqueue each
kernel with global and local sizes of one; pass2 must depend on pass1, and
readback must depend on pass2. Zero count performs no accesses.

Run the host arithmetic check:

```sh
python3 tests/opencl/run.py --build /tmp/a10-opencl-body
```

This compiles the actual OpenCL C bodies and checks every output against the
independent widened-integer reference, including overflow-heavy inputs, odd
sizes through 1,000,003 elements, untouched inputs and output boundary guards.
It does not exercise an OpenCL runtime, device memory, command events or FPGA
execution. FPGA compilation, binary loading, event ordering and physical
readback remain required integration checks. This fixture is not a bandwidth
benchmark or a complete OpenCL feature-conformance suite.

## Binary host

Build against installed OpenCL headers and the ICD loader:

```sh
cmake -S apps/opencl -B build/opencl
cmake --build build/opencl
```

After board, image and driver readiness have been independently established:

```sh
build/opencl/a10_opencl_correctness --physical workload.aocx \
  'exact platform name' 'exact accelerator name'
```

The host requires a unique exact accelerator match, checks binary status and
build results, binds the declared kernel arguments, and uses explicit event
dependencies between the two launches and readback. It checks seven sizes
against the independent reference. Errors return nonzero; it never substitutes
source compilation or another device type. Binary loading may configure the
FPGA through the runtime and must obey the board's programming/recovery gates.
Device names and numerical success alone do not certify loaded-image identity
or physical qualification. Host compilation and command-line rejection have
been checked; runtime and device execution remain unqualified.

API contracts: [binary programs](https://registry.khronos.org/OpenCL/specs/unified/refpages/man/html/clCreateProgramWithBinary.html)
and [kernel dispatch](https://registry.khronos.org/OpenCL/specs/unified/refpages/man/html/clEnqueueNDRangeKernel.html).
