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
