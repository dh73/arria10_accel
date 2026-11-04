// SPDX-License-Identifier: BSD-3-Clause
// Explicit single-memory interface for early RTL generation. These launchers
// require backend-qualified, disjoint USM buffers; they do not select a device.
#include <sycl/sycl.hpp>
#include <sycl/ext/intel/fpga_extensions.hpp>
#include <cstdint>

namespace a10_streaming {
namespace fpga = sycl::ext::intel::experimental;

// One shared physical memory path. 35 address bits match the platform adapter;
// the backend must enforce the physical 2-GiB aperture independently.
// maxburst=1 matches today's adapter, while each transfer carries 64 bytes.
// Increasing burst length requires corresponding adapter acceptance first.
template<class T>
auto memory(T* p) {
  return sycl::ext::oneapi::experimental::annotated_arg(p, fpga::register_map,
      fpga::buffer_location<0>, fpga::dwidth<512>, fpga::awidth<35>,
      fpga::latency<0>, fpga::maxburst<1>);
}

class Copy;
class Triad;

sycl::event copy(sycl::queue& queue, const std::uint32_t* input,
                 std::uint32_t* output, std::uint32_t count) {
  auto src = memory(input);
  auto dst = memory(output);
  return queue.single_task<Copy>([=] {
    const std::uint64_t blocks = std::uint64_t(count) / 16;
    for (std::uint64_t block = 0; block < blocks; ++block) {
      sycl::vec<std::uint32_t, 16> value;
      value.load(block, static_cast<const std::uint32_t*>(src));
      value.store(block, static_cast<std::uint32_t*>(dst));
    }
    for (std::uint64_t i = blocks * 16; i < count; ++i) dst[i] = src[i];
  });
}

sycl::event triad(sycl::queue& queue, const std::uint32_t* input_a,
                  const std::uint32_t* input_b, std::uint32_t* output,
                  std::uint32_t scale, std::uint32_t count) {
  auto a = memory(input_a);
  auto b = memory(input_b);
  auto dst = memory(output);
  return queue.single_task<Triad>([=] {
    const std::uint64_t blocks = std::uint64_t(count) / 16;
    for (std::uint64_t block = 0; block < blocks; ++block) {
      sycl::vec<std::uint32_t, 16> va, vb;
      va.load(block, static_cast<const std::uint32_t*>(a));
      vb.load(block, static_cast<const std::uint32_t*>(b));
      const auto value = va + vb * scale;
      value.store(block, static_cast<std::uint32_t*>(dst));
    }
    for (std::uint64_t i = blocks * 16; i < count; ++i)
      dst[i] = a[i] + b[i] * scale;
  });
}
} // namespace a10_streaming
