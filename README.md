# Arria 10 accelerator

Work in progress: an Arria 10 GX ES3 PCIe/DDR4 platform for hardware SYCL
execution, Linux DMA, and every populated board interface.

## Layout

| Folder | Contents |
|---|---|
| `rtl/` | DDR adapter, initialization integration, platform supervision |
| `host/`, `include/` | Kernel executor, DMA lifecycle, descriptor interfaces |
| `drivers/aclpci/` | Linux PCIe driver and fault-injection tests |
| `apps/` | SYCL workloads and host reference |
| `tests/` | VCS, host, and source-contract tests |
| `formal/`, `proof/` | Lean proofs and assumptions |
| `tools/` | ABI extraction, CRA correction, timing preflight |
| `containers/` | Pinned oneAPI build recipe |
| `experiments/` | Unadopted implementation candidates |
| `third_party/` | Pinned upstream runtime and DDR initializer |
| `docs/` | Technical contracts, interface inventory, roadmap |

## Host checks

```sh
git submodule update --init third_party/fpga-runtime-for-opencl
cmake -S host -B build/host \
  -DAOCL_MMD_INCLUDE_DIR="$PWD/third_party/fpga-runtime-for-opencl/include" \
  -DA10_KERNEL_EXECUTOR_SNAPSHOT_ONLY=ON
cmake --build build/host
ctest --test-dir build/host --output-on-failure
sh drivers/aclpci/tests/run-integration.sh
```

Snapshot mode tests software contracts only. It cannot admit hardware work.
RTL validation uses VCS; formal models use Lean 4.19. Compiler-generated kernels,
Quartus IP libraries, licensed tools, bitstreams and private machine records are
not distributed here. Source-bound synthesis/VCS runs require those local inputs;
the scripts retain their explicit input requirements and fail if missing.

## Status

Host components and driver fault tests pass. The driver also compiles for the
ASUS Fedora kernel. Generated-kernel VCS simulations pass through 1,000,003
elements. These results are not physical acceptance. DMA admission remains
disabled; reusable DMA ownership, reset timing, exact board constraints,
recovery, BSP integration and physical interface qualification remain open.
See [roadmap](docs/ROADMAP.md).

Keep folders organized by component. Commit source, tests and concise technical
descriptions; keep conversations, request receipts and machine logs out of Git.
Future reviews should identify an exact commit and relevant paths.
