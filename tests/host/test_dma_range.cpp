#include "asus_a10/dma_range.hpp"
#include <cstdint>
#include <limits>
#include <iostream>

int main() {
  using asus_a10::valid_dma_range;
  constexpr auto max = std::numeric_limits<std::uint64_t>::max();
  constexpr std::uint64_t ddr = std::uint64_t{1} << 31;
  static_assert(valid_dma_range(0, 0, 0));
  static_assert(valid_dma_range(ddr, ddr, 0));
  static_assert(valid_dma_range(ddr, ddr - 64, 64));
  static_assert(!valid_dma_range(ddr, ddr - 63, 64));
  static_assert(!valid_dma_range(ddr, max, 2));
  static_assert(!valid_dma_range(max, max, 1));
  static_assert(valid_dma_range(max, 1, max - 1));
  // Exhaust a small domain against widened arithmetic, including invalid inputs.
  for (std::uint64_t cap = 0; cap <= 64; ++cap)
    for (std::uint64_t offset = 0; offset <= 80; ++offset)
      for (std::uint64_t length = 0; length <= 80; ++length)
        if (valid_dma_range(cap, offset, length) != (offset + length <= cap))
          return 1;
  std::cout << "DMA range boundary and finite-domain tests: PASS\n";
}
