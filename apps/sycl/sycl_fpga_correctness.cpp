// Hardware-only SYCL FPGA end-to-end correctness workload.
//
// This file intentionally has no CPU/default/emulator selector fallback.  The
// host CPU computes a separate widened modular-integer reference. Build with
// -DFPGA_HARDWARE=1, -fintelfpga, -Xshardware and the project BSP target.

#include <sycl/ext/intel/fpga_extensions.hpp>
#include <sycl/sycl.hpp>
#include "asus_a10/workload_reference.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <exception>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#if !defined(FPGA_HARDWARE) || FPGA_HARDWARE != 1
#error "Physical acceptance binary must be compiled with -DFPGA_HARDWARE=1"
#endif
#if defined(FPGA_EMULATOR) || defined(FPGA_SIMULATOR)
#error "Emulator/simulator macros are forbidden in the physical acceptance binary"
#endif

namespace {

class Pass1Kernel;
class Pass2Kernel;

constexpr std::uint32_t RotateLeft(std::uint32_t value,
                                   std::uint32_t count) noexcept {
  // All callers pass 1..31, so neither shift is by the word width.
  return static_cast<std::uint32_t>((value << count) |
                                    (value >> (32U - count)));
}

constexpr std::uint32_t Pass1(std::uint32_t a, std::uint32_t b,
                              std::uint32_t index) noexcept {
  std::uint32_t value = static_cast<std::uint32_t>(
      a * UINT32_C(0x9e3779b1) + b + index * UINT32_C(0x85ebca6b));
  value ^= static_cast<std::uint32_t>(a >> ((index % 13U) + 1U));
  return RotateLeft(value, (index % 31U) + 1U);
}

constexpr std::uint32_t Pass2(std::uint32_t intermediate, std::uint32_t b,
                              std::uint32_t index) noexcept {
  std::uint32_t value = intermediate ^ (intermediate >> 16U);
  value = static_cast<std::uint32_t>(value * UINT32_C(0x7feb352d));
  value ^= value >> 15U;
  value = static_cast<std::uint32_t>(value * UINT32_C(0x846ca68b));
  value ^= value >> 16U;
  return static_cast<std::uint32_t>(value + RotateLeft(b ^ index, 7U));
}

std::uint32_t NextRandom(std::uint32_t* state) {
  std::uint32_t x = *state;
  x ^= x << 13U;
  x ^= x >> 17U;
  x ^= x << 5U;
  *state = x;
  return x;
}

std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

void RejectNonPhysicalIdentity(const sycl::device& device) {
  const std::string name = device.get_info<sycl::info::device::name>();
  const std::string vendor = device.get_info<sycl::info::device::vendor>();
  const std::string platform =
      device.get_platform().get_info<sycl::info::platform::name>();
  const std::string combined = Lower(name + " " + vendor + " " + platform);
  for (std::string_view forbidden : {"emulator", "simulation", "simulator",
                                     "host device", "cpu device"}) {
    if (combined.find(forbidden) != std::string::npos) {
      throw std::runtime_error("selected device identity contains forbidden non-physical marker: " +
                               std::string(forbidden));
    }
  }
  std::cout << "selector=sycl::ext::intel::fpga_selector_v\n"
            << "device.name=" << name << '\n'
            << "device.vendor=" << vendor << '\n'
            << "device.driver="
            << device.get_info<sycl::info::device::driver_version>() << '\n'
            << "platform.name=" << platform << '\n';
}

void RunOneSize(sycl::queue& queue, std::size_t count, std::uint32_t seed) {
  if (count == 0 || count > std::numeric_limits<std::uint32_t>::max()) {
    throw std::invalid_argument("element count must fit a nonzero uint32_t index");
  }

  std::vector<std::uint32_t> a(count);
  std::vector<std::uint32_t> b(count);
  std::vector<std::uint32_t> oracle(count);
  std::uint32_t state = seed ^ static_cast<std::uint32_t>(count);
  for (std::size_t i = 0; i < count; ++i) {
    a[i] = NextRandom(&state);
    b[i] = NextRandom(&state) ^ static_cast<std::uint32_t>(i * 17U);
    const std::uint32_t index = static_cast<std::uint32_t>(i);
    oracle[i] = asus_a10::workload_reference(a[i], b[i], index);
  }

  std::vector<std::uint32_t> output(count, UINT32_C(0xa5a5a5a5));
  {
    sycl::buffer<std::uint32_t, 1> a_buffer(a.data(), sycl::range<1>(count));
    sycl::buffer<std::uint32_t, 1> b_buffer(b.data(), sycl::range<1>(count));
    sycl::buffer<std::uint32_t, 1> temporary_buffer{sycl::range<1>(count)};
    sycl::buffer<std::uint32_t, 1> output_buffer(output.data(),
                                                 sycl::range<1>(count));

    const sycl::event pass1_event = queue.submit([&](sycl::handler& handler) {
      sycl::accessor a_access(a_buffer, handler, sycl::read_only);
      sycl::accessor b_access(b_buffer, handler, sycl::read_only);
      sycl::accessor temporary_access(temporary_buffer, handler,
                                      sycl::write_only, sycl::no_init);
      handler.single_task<Pass1Kernel>([=]() {
        for (std::size_t i = 0; i < count; ++i) {
          const std::uint32_t index = static_cast<std::uint32_t>(i);
          temporary_access[i] = Pass1(a_access[i], b_access[i], index);
        }
      });
    });

    sycl::event pass2_event = queue.submit([&](sycl::handler& handler) {
      handler.depends_on(pass1_event);
      sycl::accessor temporary_access(temporary_buffer, handler,
                                      sycl::read_only);
      sycl::accessor b_access(b_buffer, handler, sycl::read_only);
      sycl::accessor output_access(output_buffer, handler, sycl::write_only,
                                   sycl::no_init);
      handler.single_task<Pass2Kernel>([=]() {
        for (std::size_t i = 0; i < count; ++i) {
          const std::uint32_t index = static_cast<std::uint32_t>(i);
          output_access[i] = Pass2(temporary_access[i], b_access[i], index);
        }
      });
    });

    pass2_event.wait_and_throw();
    sycl::host_accessor observed(output_buffer, sycl::read_only);
    std::size_t mismatch_count = 0;
    for (std::size_t i = 0; i < count; ++i) {
      if (observed[i] != oracle[i]) {
        if (mismatch_count < 8) {
          std::cerr << "mismatch n=" << count << " index=" << i << " expected=0x"
                    << std::hex << std::setw(8) << std::setfill('0') << oracle[i]
                    << " observed=0x" << std::setw(8) << observed[i] << std::dec
                    << '\n';
        }
        ++mismatch_count;
      }
    }
    if (mismatch_count != 0) {
      throw std::runtime_error("FPGA result mismatch count=" +
                               std::to_string(mismatch_count));
    }
  }

  // The host vector is updated when output_buffer is destroyed.  Checking it
  // separately catches an incorrect host copy-back in addition to host_accessor
  // visibility.
  if (output != oracle) {
    throw std::runtime_error("post-destruction buffer copy-back mismatch");
  }
  std::cout << "case.count=" << count << " status=PASS\n";
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 2 || std::string_view(argv[1]) != "--physical") {
      std::cerr << "usage: " << argv[0] << " --physical\n"
                << "This binary refuses to treat CPU/emulator/simulator execution as physical acceptance.\n";
      return 64;
    }

    const auto async_handler = [](sycl::exception_list exceptions) {
      for (const std::exception_ptr& exception : exceptions) {
        std::rethrow_exception(exception);
      }
    };
    sycl::queue queue(sycl::ext::intel::fpga_selector_v, async_handler);
    RejectNonPhysicalIdentity(queue.get_device());

    constexpr std::array<std::size_t, 7> kCounts{
        1, 3, 17, 257, 4093, 65537, 1000003,
    };
    std::uint32_t seed = UINT32_C(0x6d2b79f5);
    for (const std::size_t count : kCounts) {
      RunOneSize(queue, count, seed);
      seed = static_cast<std::uint32_t>(seed * UINT32_C(1664525) +
                                        UINT32_C(1013904223));
    }
    queue.wait_and_throw();
    std::cout << "fpga_workload_data_check=PASS cases=" << kCounts.size()
              << "\n";
    return 0;
  } catch (const sycl::exception& exception) {
    std::cerr << "SYCL failure: " << exception.what() << '\n';
  } catch (const std::exception& exception) {
    std::cerr << "failure: " << exception.what() << '\n';
  }
  return 1;
}
