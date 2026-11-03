#include "asus_a10/native_dma_descriptor.hpp"
#include <algorithm>
#include <cstdlib>
#include <iostream>

void require(bool ok) { if (!ok) std::abort(); }

int main() {
  namespace dma = asus_a10::native_dma;
  std::array<std::uint8_t, 32> bytes;
  bytes.fill(0xff);
  require(dma::Encode({0x0123456789abcdefULL, 0xfedcba9876543210ULL,
                       0x2a55a, 0xa7}, bytes).ok());
  // Independent DWORD assembly from vendor BFM offsets, not codec decoding.
  constexpr std::array<std::uint8_t, 32> golden{
      0xef,0xcd,0xab,0x89,0x67,0x45,0x23,0x01,
      0x10,0x32,0x54,0x76,0x98,0xba,0xdc,0xfe,
      0x5a,0xa5,0x9e,0x02,0,0,0,0,0,0,0,0,0,0,0,0};
  require(bytes == golden);
  require(dma::Encode({UINT64_MAX, UINT64_MAX, 0x3ffff, 0xff}, bytes).ok());
  require(std::all_of(bytes.begin(), bytes.begin()+19,
                      [](auto v) { return v == 0xff; }));
  require(bytes[19] == 3);
  require(std::all_of(bytes.begin()+20, bytes.end(),
                      [](auto v) { return v == 0; }));
  const auto before = bytes;
  require(dma::Encode({0, 0, 0x40000, 0}, bytes).error ==
          asus_a10::descriptor::Error::kLengthRange);
  require(bytes == before); // Failed encoding leaves output untouched.
  std::cout << "native DMA source-layout vectors: PASS\n";
}
