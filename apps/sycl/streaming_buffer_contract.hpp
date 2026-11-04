// SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace a10_streaming_contract {
// Compare byte ranges without pointer ordering or overflowing end addresses.
inline void require_disjoint(std::uintptr_t a, std::uintptr_t b,
                             std::uint32_t count) {
  const std::uint64_t bytes = std::uint64_t(count) * sizeof(std::uint32_t);
  if (!bytes) return;
  const auto max = std::numeric_limits<std::uintptr_t>::max();
  if (!a || !b || bytes > max || a > max - bytes || b > max - bytes)
    throw std::invalid_argument("Invalid streaming buffer range");
  if (a < b + bytes && b < a + bytes)
    throw std::invalid_argument("Streaming buffers must be disjoint");
}
}
