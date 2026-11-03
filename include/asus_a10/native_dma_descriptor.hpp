#ifndef ASUS_A10_NATIVE_DMA_DESCRIPTOR_HPP
#define ASUS_A10_NATIVE_DMA_DESCRIPTOR_HPP

#include "asus_a10/descriptor_codec.hpp"

// Retained vendor example ABI only. This does not identify the live FPGA image.
// Source and RTL decode provenance: docs/NATIVE_DMA_DESCRIPTOR.md.
namespace asus_a10::native_dma {
inline constexpr std::array<descriptor::Field, 4> fields{{
    {"source", 0, 64}, {"destination", 64, 64},
    {"length_dwords", 128, 18}, {"id", 146, 8},
}};
inline constexpr descriptor::Schema schema{32, fields};
inline constexpr descriptor::ArvvFieldNames names{
    "source", "destination", "length_dwords", "id"};

// Serialization only: DMA mapping, alignment, lifetime, address authorization,
// and ring admission must be validated before submitting this record.
[[nodiscard]] inline descriptor::Status Encode(
    const descriptor::ArvvDescriptorValues& value,
    std::span<std::uint8_t, 32> output) noexcept {
  return descriptor::EncodeArvvDescriptor(schema, names, value, output);
}
}  // namespace asus_a10::native_dma
#endif
