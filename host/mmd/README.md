# Injectable Arria 10 MMD adapter

`a10_mmd_adapter` builds a shared library implementing the pinned Intel
`MMD/aocl_mmd.h` C entry points for discovery, open/info, status and interrupt
handler registration, read/write/copy, yield, and close. Its required-symbol
surface follows `third_party/fpga-runtime-for-opencl/src/acl_hal_mmd.cpp`.
There is no default transport and no discovered board without explicit backend
registration. This is a host adapter foundation, not an installed BSP or an
operational OpenCL/SYCL platform.

`adapter.hpp` defines project-owned interfaces, not a speculative kernel UAPI.
A backend supplies actual discovery, vendor/memory capability queries, device
information, and a transport. A transport must establish live qualified image
identity and exclusive custody before open succeeds. Backend factory/open and
close calls must not reenter registry-mutating APIs. Transport implementations
must synchronize concurrent submission, yield, and interrupt registration.
Production code must connect these contracts to the accepted driver/image ABI;
no ioctl, register offsets, board identity, or interrupt semantics are guessed.

All host payloads use adapter-owned staging. A write copies caller bytes before
submission. A read copies back only on a drained successful completion before
calling its captured runtime handler. Copy has no host payload but retains its
operation reservation. The existing lifecycle uses unique generation/sequence
tickets, and a separate token index prevents concurrent runtime-token reuse.
Handlers are captured at admission; reentrant submission may reuse the token.
No adapter mutex is held while invoking a runtime callback. Status exceptions
are contained by the lifecycle dispatcher and release still occurs.

The synchronous transport method is `noexcept` and MUST return only after all
hardware references have drained, including error returns. An asynchronous
transport reports Accepted, NotAccepted, or Indeterminate. An exception means
Indeterminate. Unknown acceptance retains staging and forces the lifecycle
offline; there is no callback and no safe release until actual drain. Late
completion for an orphan can release staging without accessing the caller's
read destination. Once accepted, failure to allocate dispatcher work retains
callback debt and still returns successful launch, so the runtime cannot infer
that the read destination is reusable. This containment has no automatic
allocation-failure retry or hardware recovery implementation.

Close refuses outstanding calls, staged allocations, callback work, or lifecycle
debt, leaving the handle serviceable for completion/yield. It does not cancel
operations or infer drain. After an empty-debt close starts, failed/throwing
transport close retains the handle and custody but disables new calls; recovery
for this state remains future backend work. Unqualified transports whose close
fails remain quarantined. The registry intentionally survives static destruction
so unresolved hardware resources are never implicitly released by exit order.
Do not unload the shared library while any handle/producer/callback remains.
`flush_ready` is an internal fence for already-ready work, not a hardware wait.

The fake backend tests synchronous staging, async read/write/copy, early and
duplicate completion, callback reentry/token reuse, handler requirements,
invalid handles, overflow, missing drain, rejected/throwing submissions,
qualification refusal and outstanding-close refusal. They establish host
ownership behavior only. The fake backend is compiled solely into the test.
Interrupt delivery, generated-kernel executor wiring, driver transport,
programming, capability advertisement, package discovery and actual runtime
loading/device execution remain unqualified.

Validation from repository root:

```sh
cmake -S host -B /tmp/a10-mmd-adapter-build \
  -DAOCL_MMD_INCLUDE_DIR="$PWD/third_party/fpga-runtime-for-opencl/include" \
  -DA10_BUILD_KERNEL_EXECUTOR=OFF
cmake --build /tmp/a10-mmd-adapter-build -j4
ctest --test-dir /tmp/a10-mmd-adapter-build --output-on-failure
```

Both lifecycle and adapter tests pass with GCC 8.5.0 and, separately, Clang
21.1.8 using `-fsanitize=address,undefined -fno-omit-frame-pointer` on compile
and `-fsanitize=address,undefined` on executable/shared-library links. The
installed GCC ASan linker target `/usr/lib64/libasan.so.5.0.0` is missing;
its sanitizer configuration did not build or run tests. No software was installed.
