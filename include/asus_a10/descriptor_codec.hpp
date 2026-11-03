#ifndef ASUS_A10_DESCRIPTOR_CODEC_HPP
#define ASUS_A10_DESCRIPTOR_CODEC_HPP

// Bounds-safe, source-independent descriptor bit-packer.
//
// IMPORTANT: this file intentionally contains no ARVV/C126 bit offsets.  The
// supplied handoff establishes only a 32-byte record with 64-bit source and
// destination addresses, an 18-bit DWORD length, and an 8-bit descriptor ID.
// The owner must populate Field.bit_offset from the actual selected RTL/BFM
// contract before this code is used with hardware.  Unspecified bits are zero.

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace asus_a10::descriptor {

constexpr std::size_t kArvvRecordBytes = 32;
constexpr std::uint32_t kMaxLengthDwords = (std::uint32_t{1} << 18) - 1;

struct Field {
  std::string_view name;
  std::uint16_t bit_offset;
  std::uint8_t bit_width;
};

struct Schema {
  std::size_t record_bytes;
  std::span<const Field> fields;
};

struct NamedValue {
  std::string_view name;
  std::uint64_t value;
};

enum class Error {
  kOk = 0,
  kNullOutput,
  kRecordSize,
  kEmptyName,
  kFieldWidth,
  kFieldBounds,
  kDuplicateField,
  kOverlappingFields,
  kUnknownValue,
  kDuplicateValue,
  kMissingValue,
  kValueTooWide,
  kOutputSize,
  kFieldNotFound,
  kSemanticSchema,
  kLengthRange,
};

struct Status {
  Error error;
  std::string_view detail;

  [[nodiscard]] constexpr bool ok() const noexcept { return error == Error::kOk; }
  [[nodiscard]] constexpr explicit operator bool() const noexcept { return ok(); }
};

constexpr Status Ok() noexcept { return {Error::kOk, "ok"}; }

[[nodiscard]] inline const Field* FindField(const Schema& schema,
                                            std::string_view name) noexcept {
  for (const Field& field : schema.fields) {
    if (field.name == name) {
      return &field;
    }
  }
  return nullptr;
}

[[nodiscard]] inline const NamedValue* FindValue(
    std::span<const NamedValue> values, std::string_view name) noexcept {
  for (const NamedValue& value : values) {
    if (value.name == name) {
      return &value;
    }
  }
  return nullptr;
}

[[nodiscard]] inline Status ValidateSchema(const Schema& schema) noexcept {
  if (schema.record_bytes == 0 || schema.record_bytes > 8192) {
    return {Error::kRecordSize, "record_bytes must be in [1,8192]"};
  }
  const std::size_t total_bits = schema.record_bytes * 8;
  for (std::size_t i = 0; i < schema.fields.size(); ++i) {
    const Field& field = schema.fields[i];
    if (field.name.empty()) {
      return {Error::kEmptyName, "field name is empty"};
    }
    if (field.bit_width == 0 || field.bit_width > 64) {
      return {Error::kFieldWidth, "field width must be in [1,64]"};
    }
    const std::size_t begin = field.bit_offset;
    const std::size_t end = begin + field.bit_width;
    if (end > total_bits || end < begin) {
      return {Error::kFieldBounds, "field extends beyond record"};
    }
    for (std::size_t j = 0; j < i; ++j) {
      const Field& prior = schema.fields[j];
      if (prior.name == field.name) {
        return {Error::kDuplicateField, "duplicate field name"};
      }
      const std::size_t prior_begin = prior.bit_offset;
      const std::size_t prior_end = prior_begin + prior.bit_width;
      if (begin < prior_end && prior_begin < end) {
        return {Error::kOverlappingFields, "fields overlap"};
      }
    }
  }
  return Ok();
}

[[nodiscard]] inline bool ValueFits(std::uint64_t value,
                                    std::uint8_t width) noexcept {
  return width == 64 || value < (std::uint64_t{1} << width);
}

inline void WriteBitsLittleEndian(std::span<std::uint8_t> output,
                                  std::uint16_t bit_offset,
                                  std::uint8_t bit_width,
                                  std::uint64_t value) noexcept {
  // Contract: bit 0 is the least-significant bit of byte 0.  This convention is
  // explicit and must match the owner-supplied RTL/BFM schema before use.
  for (std::uint8_t source_bit = 0; source_bit < bit_width; ++source_bit) {
    const std::size_t destination_bit = bit_offset + source_bit;
    const std::size_t byte_index = destination_bit / 8;
    const std::uint8_t mask = static_cast<std::uint8_t>(
        std::uint8_t{1} << static_cast<unsigned>(destination_bit % 8));
    if (((value >> source_bit) & std::uint64_t{1}) != 0) {
      output[byte_index] = static_cast<std::uint8_t>(output[byte_index] | mask);
    } else {
      output[byte_index] = static_cast<std::uint8_t>(output[byte_index] & ~mask);
    }
  }
}

[[nodiscard]] inline std::uint64_t ReadBitsLittleEndian(
    std::span<const std::uint8_t> input, std::uint16_t bit_offset,
    std::uint8_t bit_width) noexcept {
  std::uint64_t value = 0;
  for (std::uint8_t destination_bit = 0; destination_bit < bit_width;
       ++destination_bit) {
    const std::size_t source_bit = bit_offset + destination_bit;
    const std::size_t byte_index = source_bit / 8;
    const std::uint8_t mask = static_cast<std::uint8_t>(
        std::uint8_t{1} << static_cast<unsigned>(source_bit % 8));
    if ((input[byte_index] & mask) != 0) {
      value |= std::uint64_t{1} << destination_bit;
    }
  }
  return value;
}

[[nodiscard]] inline Status EncodeExact(
    const Schema& schema, std::span<const NamedValue> values,
    std::span<std::uint8_t> output) noexcept {
  const Status schema_status = ValidateSchema(schema);
  if (!schema_status) {
    return schema_status;
  }
  if (output.size() != schema.record_bytes) {
    return {Error::kOutputSize, "output size differs from schema.record_bytes"};
  }

  for (std::size_t i = 0; i < values.size(); ++i) {
    if (FindField(schema, values[i].name) == nullptr) {
      return {Error::kUnknownValue, "value name is not present in schema"};
    }
    for (std::size_t j = 0; j < i; ++j) {
      if (values[i].name == values[j].name) {
        return {Error::kDuplicateValue, "duplicate named value"};
      }
    }
  }

  for (const Field& field : schema.fields) {
    const NamedValue* value = FindValue(values, field.name);
    if (value == nullptr) {
      return {Error::kMissingValue, "schema field has no supplied value"};
    }
    if (!ValueFits(value->value, field.bit_width)) {
      return {Error::kValueTooWide, "value does not fit field width"};
    }
  }

  for (std::uint8_t& byte : output) {
    byte = 0;
  }
  for (const Field& field : schema.fields) {
    const NamedValue* value = FindValue(values, field.name);
    WriteBitsLittleEndian(output, field.bit_offset, field.bit_width,
                          value->value);
  }
  return Ok();
}

[[nodiscard]] inline Status DecodeField(
    const Schema& schema, std::span<const std::uint8_t> input,
    std::string_view field_name, std::uint64_t* value) noexcept {
  if (value == nullptr) {
    return {Error::kNullOutput, "decode output pointer is null"};
  }
  const Status schema_status = ValidateSchema(schema);
  if (!schema_status) {
    return schema_status;
  }
  if (input.size() != schema.record_bytes) {
    return {Error::kOutputSize, "input size differs from schema.record_bytes"};
  }
  const Field* field = FindField(schema, field_name);
  if (field == nullptr) {
    return {Error::kFieldNotFound, "requested field is absent"};
  }
  *value = ReadBitsLittleEndian(input, field->bit_offset, field->bit_width);
  return Ok();
}

struct ArvvFieldNames {
  std::string_view source_address;
  std::string_view destination_address;
  std::string_view length_dwords;
  std::string_view descriptor_id;
};

struct ArvvDescriptorValues {
  std::uint64_t source_address;
  std::uint64_t destination_address;
  std::uint32_t length_dwords;
  std::uint8_t descriptor_id;
};

[[nodiscard]] inline Status ValidateArvvSemanticSchema(
    const Schema& schema, const ArvvFieldNames& names) noexcept {
  const Status generic = ValidateSchema(schema);
  if (!generic) {
    return generic;
  }
  if (schema.record_bytes != kArvvRecordBytes || schema.fields.size() != 4) {
    return {Error::kSemanticSchema,
            "ARVV semantic schema must be exactly four fields in 32 bytes"};
  }
  const Field* source = FindField(schema, names.source_address);
  const Field* destination = FindField(schema, names.destination_address);
  const Field* length = FindField(schema, names.length_dwords);
  const Field* id = FindField(schema, names.descriptor_id);
  if (source == nullptr || destination == nullptr || length == nullptr ||
      id == nullptr) {
    return {Error::kSemanticSchema, "one or more semantic fields are absent"};
  }
  if (source->bit_width != 64 || destination->bit_width != 64 ||
      length->bit_width != 18 || id->bit_width != 8) {
    return {Error::kSemanticSchema,
            "semantic field widths must be 64/64/18/8"};
  }
  return Ok();
}

[[nodiscard]] inline Status EncodeArvvDescriptor(
    const Schema& schema, const ArvvFieldNames& names,
    const ArvvDescriptorValues& descriptor,
    std::span<std::uint8_t, kArvvRecordBytes> output) noexcept {
  const Status semantic = ValidateArvvSemanticSchema(schema, names);
  if (!semantic) {
    return semantic;
  }
  if (descriptor.length_dwords > kMaxLengthDwords) {
    return {Error::kLengthRange, "length exceeds the supplied 18-bit contract"};
  }
  const std::array<NamedValue, 4> values{{
      {names.source_address, descriptor.source_address},
      {names.destination_address, descriptor.destination_address},
      {names.length_dwords, descriptor.length_dwords},
      {names.descriptor_id, descriptor.descriptor_id},
  }};
  return EncodeExact(schema, values, output);
}

}  // namespace asus_a10::descriptor

#endif  // ASUS_A10_DESCRIPTOR_CODEC_HPP
