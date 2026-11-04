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
zero-duration, sub-resolution, reversed or overlapping dependent timestamp fails measurement.
Small cases can fall below the timer resolution and require a longer workload
before a rate can be reported.

`algorithm_bytes = 24 * count` counts two logical 32-bit reads and one write
per element in each of two passes. `algorithm_GBps = algorithm_bytes / span_ns`
uses decimal GB/s and includes the inter-kernel gap. This is an algorithm-level
rate, not measured DDR bus traffic, PCIe bandwidth, end-to-end throughput or a
maximum-bandwidth result. Cache behavior, physical bus counters, transfer times
and a comparable baseline are separate measurements.

[Event profiling contract](https://registry.khronos.org/OpenCL/specs/unified/refpages/man/html/clGetEventProfilingInfo.html).

## Vector streaming kernels

`streaming.cl` provides `stream_copy512(input, output, count)` and
`stream_triad512(a, b, output, scale, count)`. Counts are 32-bit unsigned element
counts; scale is unsigned and triad arithmetic wraps modulo 2^32. Buffers must
be disjoint and 64-byte aligned. Launch one work item. Full groups use `uint16`
loads/stores and the remaining 0..15 elements use scalar accesses without
reading or writing beyond the requested count.

```sh
python3 tests/opencl/run_streaming.py --build /tmp/a10-opencl-stream
```

The host arithmetic fixture checks 70 sizes, every tail residue, five scale
values, unchanged inputs and boundary guards. It executes the actual compiled
kernel bodies; it does not exercise an FPGA memory port or runtime. The binary host selects these kernels with the optional `--streaming` argument
after the exact device name; supply a binary compiled from `streaming.cl`.
It requires at least 512-bit buffer-base alignment, verifies copy before
launching triad, and reports each kernel duration and logical byte rate
separately. Poison writes and readbacks are outside those kernel durations.

Copy algorithm traffic is `8 * count` bytes (one read, one write); triad is
`12 * count` bytes (two reads, one write). Report rate against actual kernel
event durations only after numerical validation. These logical byte counts are
not physical bus counters. A `uint16` expression does not establish a 512-bit
external master: generated port widths, burst behavior, interconnect arbitration,
fit/timing and physical counters must qualify the resulting memory path.

The host failure fixture also covers streaming argument layouts, alignment
rejection, separate copy/triad corruption and every successful-path API call.
Its streaming execution uses reference arithmetic; `run_streaming.py` separately
executes the actual vector kernel bodies. Neither fixture establishes runtime
or physical bandwidth acceptance.

## Working-set size

Append `--count N` to select a nonzero decimal element count instead of the
seven-size correctness suite. For example, after hardware readiness is met:

```sh
build/opencl/a10_opencl_correctness --physical streaming.aocx \
  'exact platform name' 'exact accelerator name' --streaming --count 16777216
```

The host checks each buffer against `CL_DEVICE_MAX_MEM_ALLOC_SIZE`, and the
combined three streaming buffers (four correctness buffers) against reported
global memory before creating a context or loading the binary. These are actual
reported capacity bounds, not a fixed workload cap. Runtime allocation may
still fail because memory is shared or reserved; such failures remain errors.
The element ABI is uint32 and host byte-size arithmetic is checked. Larger
working sets alone do not prove external-memory traffic or peak bandwidth.

## Transfer timing

Streaming mode also reports `OPENCL_TRANSFER_TIMING` for the two input uploads
and each verified output download. `bytes = 4 * count`; `payload_GBps` divides
that payload by the transfer event's START-to-END duration in nanoseconds.
Download timing must follow its producing kernel. All durations must be
positive and at least the reported device timer resolution. Upload rates are
printed only after both copy and triad readbacks pass.

These are individual blocking OpenCL command rates. They exclude allocation,
API submission, poison writes and verification; they do not establish PCIe
wire utilization, simultaneous bidirectional throughput, sustained saturation
or end-to-end application throughput. Runtime staging and caching can affect
what the event measures. Physical comparison requires the same workload size,
transfer policy, image identity and validated runtime on both platforms, plus
repeated measurements and independent link/traffic evidence.

Streaming mode additionally reports `OPENCL_HOST_WORKLOAD_TIMING` using the
host's monotonic clock. Each count covers host input initialization, buffer
allocation, uploads, argument setup, output poisoning, copy and triad execution,
blocking readbacks, numerical verification, and intervening result reporting.
The interval ends after both workloads pass. It excludes platform discovery,
context/program creation, binary loading, and buffer destruction; it is not
whole-process startup latency. This duration is separate from device-event
rates and cannot establish PCIe wire utilization or physical DDR bandwidth.
