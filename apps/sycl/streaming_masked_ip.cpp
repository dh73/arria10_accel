// SPDX-License-Identifier: BSD-3-Clause
// Throughput candidate: one masked, non-aliasing 16-lane loop including tails.
// Explicit single-memory interface for early RTL generation. These launchers
// require backend-qualified, disjoint USM buffers; they do not select a device.
#include <sycl/sycl.hpp>
#include <sycl/ext/intel/fpga_extensions.hpp>
#include <cstdint>
#include <stdexcept>
#include "streaming_buffer_contract.hpp"

namespace a10_streaming_masked {
namespace fpga = sycl::ext::intel::experimental;

// One shared physical memory path. 35 address bits match the platform adapter;
// the backend must enforce the physical 2-GiB aperture independently.
// maxburst=1 matches today's adapter, while each transfer carries 64 bytes.
// Increasing burst length requires corresponding adapter acceptance first.
template<class T>
auto memory(T* p) {
  if ((reinterpret_cast<std::uintptr_t>(p) & 63) != 0)
    throw std::invalid_argument("Streaming buffers require 64-byte alignment");
  return sycl::ext::oneapi::experimental::annotated_arg(p, fpga::register_map,
      fpga::buffer_location<0>, fpga::dwidth<512>, fpga::awidth<35>,
      fpga::latency<0>, fpga::maxburst<1>,
      sycl::ext::oneapi::experimental::alignment<64>);
}

class Copy;
class Triad;

sycl::event copy(sycl::queue& queue, const std::uint32_t* input,
                 std::uint32_t* output, std::uint32_t count) {
  a10_streaming_contract::require_disjoint(
      reinterpret_cast<std::uintptr_t>(input),
      reinterpret_cast<std::uintptr_t>(output), count);
  auto src = memory(input);
  auto dst = memory(output);
  return queue.single_task<Copy>([=]() [[intel::kernel_args_restrict]] {
    const std::uint64_t blocks = (std::uint64_t(count) + 15) / 16;
    for (std::uint64_t block = 0; block < blocks; ++block) {
      // Constant-bound lanes expose independent accesses without the
      // implementation loops inside vec.load/store. Compiler coalescing and
      // initiation interval must be checked in the generated report.
      #pragma unroll
      for (unsigned lane = 0; lane < 16; ++lane) {
        const std::uint64_t i = block * 16 + lane;
        if (i < count) dst[i] = src[i];
      }
    }
  });
}

sycl::event triad(sycl::queue& queue, const std::uint32_t* input_a,
                  const std::uint32_t* input_b, std::uint32_t* output,
                  std::uint32_t scale, std::uint32_t count) {
  const auto pa = reinterpret_cast<std::uintptr_t>(input_a);
  const auto pb = reinterpret_cast<std::uintptr_t>(input_b);
  const auto po = reinterpret_cast<std::uintptr_t>(output);
  a10_streaming_contract::require_disjoint(pa, pb, count);
  a10_streaming_contract::require_disjoint(pa, po, count);
  a10_streaming_contract::require_disjoint(pb, po, count);
  auto a = memory(input_a);
  auto b = memory(input_b);
  auto dst = memory(output);
  return queue.single_task<Triad>([=]() [[intel::kernel_args_restrict]] {
    const std::uint64_t blocks = (std::uint64_t(count) + 15) / 16;
    for (std::uint64_t block = 0; block < blocks; ++block) {
      #pragma unroll
      for (unsigned lane = 0; lane < 16; ++lane) {
        const std::uint64_t i = block * 16 + lane;
        if (i < count) dst[i] = a[i] + b[i] * scale;
      }
    }
  });
}
} // namespace a10_streaming_masked
