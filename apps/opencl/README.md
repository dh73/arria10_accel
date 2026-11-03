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

## Host failure tests

```sh
python3 tests/opencl/run_host_tests.py --build /tmp/a10-opencl-host-tests \
  --opencl-include /path/to/opencl/headers
```

The test links the actual host with a fake runtime and the compiled kernel
bodies, without loading an ICD. It asserts launch dimensions, argument sizes,
buffer bounds, explicit event dependencies and balanced handle release. Every
API call on the successful path is independently failed; separate cases reject
duplicate identity, invalid binary status and corrupted readback. The fixture
is synchronous: it does not qualify runtime scheduling, asynchronous object
retention, DMA, device faults or physical execution.

## Timing output

The queue enables event profiling and reports timer resolution, both kernel
execution durations and the span from pass1 start to pass2 end. A missing,
zero-duration, reversed or overlapping dependent timestamp fails measurement.
Small cases can fall below the timer resolution and require a longer workload
before a rate can be reported.

`algorithm_bytes = 24 * count` counts two logical 32-bit reads and one write
per element in each of two passes. `algorithm_GBps = algorithm_bytes / span_ns`
uses decimal GB/s and includes the inter-kernel gap. This is an algorithm-level
rate, not measured DDR bus traffic, PCIe bandwidth, end-to-end throughput or a
maximum-bandwidth result. Cache behavior, physical bus counters, transfer times
and a comparable baseline are separate measurements.

[Event profiling contract](https://registry.khronos.org/OpenCL/specs/unified/refpages/man/html/clGetEventProfilingInfo.html).
