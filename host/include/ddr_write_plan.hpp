#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace asus::a10::memory {
enum class WriteRoute { MaskedWord, Dma };
struct WriteSegment {
  WriteRoute route{};
  std::uint64_t device_address{};
  std::size_t source_offset{}, bytes{};
  std::uint32_t data{};
  std::uint8_t mask{};
};
struct WritePlan {
  bool valid{false};
  std::size_t count{0};
  std::array<WriteSegment,3> segments{};
};
// Snapshot edge bytes without reading device memory. The caller retains bulk
// staging until DMA drains and executes segments under one owned context.
// A plan establishes neither submission nor completion/visibility.
WritePlan plan_write(std::uint64_t aperture_bytes, std::uint64_t address,
                     const void* source, std::size_t bytes) noexcept;
}
