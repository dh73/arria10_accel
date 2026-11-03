# Arria 10 accelerator

An Arria 10 GX ES3 PCIe/DDR4 compute platform for SYCL/OpenCL workloads, Linux DMA,
and board-interface integration. Implementation and hardware qualification are in progress.

## Source

| Folder | Contents |
|---|---|
| `rtl/` | DDR adapter, initialization and platform supervision |
| `host/`, `include/` | Kernel execution, DMA lifecycle and descriptor interfaces |
| `drivers/aclpci/` | Linux PCIe driver and fault-injection tests |
| `apps/` | SYCL/OpenCL workloads and reference results |
| `tests/` | RTL, host and interface tests |
| `formal/`, `proof/` | Formal models and proofs |
| `tools/` | Interface extraction, source transforms and timing checks |
| `containers/` | Build environment recipe |
| `experiments/` | Experimental DMA implementations |
| `third_party/` | Runtime dependency and DDR initializer |
| `docs/` | Interface inventory and implementation roadmap |

## Host tests

```sh
git submodule update --init third_party/fpga-runtime-for-opencl
cmake -S host -B build/host \
  -DAOCL_MMD_INCLUDE_DIR="$PWD/third_party/fpga-runtime-for-opencl/include" \
  -DA10_KERNEL_EXECUTOR_SNAPSHOT_ONLY=ON
cmake --build build/host
ctest --test-dir build/host --output-on-failure
sh drivers/aclpci/tests/run-integration.sh
```

Host and simulation tests cover execution, ownership, error handling and data
integrity. Physical board qualification remains open. See [roadmap](docs/ROADMAP.md).
