#include "descriptor_codec.hpp"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <span>
#include <string_view>

namespace desc = asus_a10::descriptor;

namespace {

[[noreturn]] void Fail(std::string_view message) {
  std::cerr << "FAIL: " << message << '\n';
  std::exit(1);
}

void Expect(bool condition, std::string_view message) {
  if (!condition) {
    Fail(message);
  }
}

// SYNTHETIC TEST OFFSETS ONLY.  They deliberately cross byte boundaries and
// are not asserted to match the omitted 81 KiB BFM contract or any live image.
constexpr std::array<desc::Field, 4> kSyntheticFields{{
    {"src", 3, 64},
    {"dst", 71, 64},
    {"len", 139, 18},
    {"id", 163, 8},
}};
constexpr desc::Schema kSyntheticSchema{32, kSyntheticFields};
constexpr desc::ArvvFieldNames kNames{"src", "dst", "len", "id"};

void TestRoundTripAndZeroReservedBits() {
  std::array<std::uint8_t, 32> bytes{};
  const desc::ArvvDescriptorValues input{
      0x0123456789abcdefULL,
      0xfedcba9876543210ULL,
      0x2a55a,
      0xa7,
  };
  const desc::Status status =
      desc::EncodeArvvDescriptor(kSyntheticSchema, kNames, input, bytes);
  Expect(status.ok(), "synthetic descriptor must encode");

  std::uint64_t value = 0;
  Expect(desc::DecodeField(kSyntheticSchema, bytes, "src", &value).ok(),
         "src decode status");
  Expect(value == input.source_address, "src round trip");
  Expect(desc::DecodeField(kSyntheticSchema, bytes, "dst", &value).ok(),
         "dst decode status");
  Expect(value == input.destination_address, "dst round trip");
  Expect(desc::DecodeField(kSyntheticSchema, bytes, "len", &value).ok(),
         "len decode status");
  Expect(value == input.length_dwords, "len round trip");
  Expect(desc::DecodeField(kSyntheticSchema, bytes, "id", &value).ok(),
         "id decode status");
  Expect(value == input.descriptor_id, "id round trip");

  // Bit 0 and the final byte are outside every synthetic field.
  Expect((bytes[0] & 0x07U) == 0, "leading reserved bits must be zero");
  Expect(bytes[31] == 0, "trailing reserved byte must be zero");
}

void TestSchemaFailures() {
  constexpr std::array<desc::Field, 2> overlap{{
      {"a", 0, 16},
      {"b", 8, 8},
  }};
  Expect(desc::ValidateSchema({32, overlap}).error ==
             desc::Error::kOverlappingFields,
         "overlap rejected");

  constexpr std::array<desc::Field, 1> out_of_bounds{{
      {"a", 255, 2},
  }};
  Expect(desc::ValidateSchema({32, out_of_bounds}).error ==
             desc::Error::kFieldBounds,
         "out-of-bounds field rejected");

  constexpr std::array<desc::Field, 2> duplicate{{
      {"a", 0, 8},
      {"a", 8, 8},
  }};
  Expect(desc::ValidateSchema({32, duplicate}).error ==
             desc::Error::kDuplicateField,
         "duplicate name rejected");
}

void TestValueFailures() {
  std::array<std::uint8_t, 32> bytes{};
  constexpr std::array<desc::NamedValue, 4> too_wide{{
      {"src", 1},
      {"dst", 2},
      {"len", std::uint64_t{1} << 18},
      {"id", 3},
  }};
  Expect(desc::EncodeExact(kSyntheticSchema, too_wide, bytes).error ==
             desc::Error::kValueTooWide,
         "generic field overflow rejected");

  constexpr std::array<desc::NamedValue, 3> missing{{
      {"src", 1},
      {"dst", 2},
      {"len", 3},
  }};
  Expect(desc::EncodeExact(kSyntheticSchema, missing, bytes).error ==
             desc::Error::kMissingValue,
         "missing field rejected");

  constexpr std::array<desc::NamedValue, 5> unknown{{
      {"src", 1},
      {"dst", 2},
      {"len", 3},
      {"id", 4},
      {"flags", 5},
  }};
  Expect(desc::EncodeExact(kSyntheticSchema, unknown, bytes).error ==
             desc::Error::kUnknownValue,
         "unknown field rejected");
}

void TestSemanticLimitsAndCallerSuppliedPacking() {
  std::array<std::uint8_t, 32> bytes{};
  const desc::ArvvDescriptorValues too_long{0, 0,
                                             desc::kMaxLengthDwords + 1U, 0};
  Expect(desc::EncodeArvvDescriptor(kSyntheticSchema, kNames, too_long, bytes)
             .error == desc::Error::kLengthRange,
         "18-bit semantic length enforced");

  constexpr std::array<desc::Field, 4> wrong_width{{
      {"src", 0, 63},
      {"dst", 64, 64},
      {"len", 128, 18},
      {"id", 146, 8},
  }};
  Expect(desc::ValidateArvvSemanticSchema({32, wrong_width}, kNames).error ==
             desc::Error::kSemanticSchema,
         "semantic widths enforced without inventing offsets");

  constexpr desc::ArvvFieldNames wrong_names{"source", "dst", "len", "id"};
  Expect(desc::ValidateArvvSemanticSchema(kSyntheticSchema, wrong_names).error ==
             desc::Error::kSemanticSchema,
         "caller must bind names to the retrieved contract");
}

}  // namespace

int main() {
  TestRoundTripAndZeroReservedBits();
  TestSchemaFailures();
  TestValueFailures();
  TestSemanticLimitsAndCallerSuppliedPacking();
  std::cout << "descriptor codec tests: PASS\n";
  return 0;
}
