#pragma once
#include <cstdint>

namespace asus_a10 {
// Host-only modular-integer reference. It does not call the SYCL kernel helpers.
// Reduce products separately before adding: their unreduced sum can exceed 64 bits.
constexpr std::uint32_t workload_reference(std::uint32_t a, std::uint32_t b,
                                          std::uint32_t index) noexcept {
  constexpr std::uint64_t modulus = std::uint64_t{1} << 32;
  auto rotate = [](std::uint64_t value, unsigned count) {
    constexpr std::uint64_t m = std::uint64_t{1} << 32;
    return (value * (std::uint64_t{1} << count) % m) +
           value / (std::uint64_t{1} << (32 - count));
  };
  std::uint64_t value = (std::uint64_t{a} * 0x9e3779b1ULL % modulus + b +
                        std::uint64_t{index} * 0x85ebca6bULL % modulus) % modulus;
  value ^= std::uint64_t{a} / (std::uint64_t{1} << (index % 13 + 1));
  value = rotate(value, index % 31 + 1);
  value ^= value / 65536;
  value = value * 0x7feb352dULL % modulus;
  value ^= value / 32768;
  value = value * 0x846ca68bULL % modulus;
  value ^= value / 65536;
  return static_cast<std::uint32_t>((value + rotate(b ^ index, 7)) % modulus);
}
} // namespace asus_a10
