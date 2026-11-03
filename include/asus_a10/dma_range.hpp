#pragma once
#include <cstdint>

namespace asus_a10 {
// Byte ranges are half-open. Empty transfers at the aperture end are valid.
// Check before addition so an untrusted offset/length cannot wrap uint64_t.
constexpr bool valid_dma_range(std::uint64_t capacity, std::uint64_t offset,
                               std::uint64_t length) noexcept {
  return offset <= capacity && length <= capacity - offset;
}
} // namespace asus_a10
