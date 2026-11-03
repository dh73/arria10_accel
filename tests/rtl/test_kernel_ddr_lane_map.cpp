#include "Vkernel_ddr_lane_map.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>

static void require(bool ok, const char* message) {
  if (!ok) { std::cerr << message << '\n'; std::abort(); }
}

int main() {
  Vkernel_ddr_lane_map dut;
  for (unsigned b=0; b<64; ++b) {
    if (b%4 == 0) dut.line_readdata[b/4] = 0;
    dut.line_readdata[b/4] |= (b ^ 0xadU) << (8*(b%4));
  }
  auto check = [&](std::uint64_t address) {
    dut.byte_address = address;
    dut.eval();
    require(dut.address_valid, "valid address rejected");
    require(std::uint64_t(dut.line_address)*64 + dut.word_lane*8 == address,
            "address reconstruction failed");
    for (unsigned b=0; b<64; ++b) {
      bool selected = b/8 == dut.word_lane;
      auto byte = (dut.line_writedata[b/4] >> (8*(b%4))) & 255U;
      auto expected = selected ? (dut.word_writedata >> (8*(b%8))) & 255U : 0;
      require(byte == expected, "write lane data mismatch");
      require(((dut.line_byteenable >> b)&1U) ==
              (selected ? (dut.word_byteenable >> (b%8))&1U : 0),
              "byte enable mismatch");
      if (selected)
        require(((dut.word_readdata >> (8*(b%8)))&255U) == (b ^ 0xadU),
                "read lane mismatch");
    }
  };
  dut.word_writedata = UINT64_C(0x0123456789abcdef);
  for (unsigned mask=0; mask<256; ++mask) {
    dut.word_byteenable = mask;
    for (unsigned lane=0; lane<8; ++lane) {
      check(lane*8);
      check(UINT64_C(0x7fffffc0)+lane*8);
    }
  }
  for (unsigned bit=0; bit<64; ++bit) {
    dut.word_writedata = UINT64_C(1) << bit;
    for (unsigned lane=0; lane<8; ++lane) check(lane*8);
  }
  auto invalid = [&](std::uint64_t address) {
    dut.byte_address=address; dut.eval();
    require(!dut.address_valid && !dut.line_address && !dut.word_lane &&
            !dut.line_byteenable && !dut.word_readdata, "invalid address alias");
    for (unsigned i=0; i<16; ++i)
      require(dut.line_writedata[i]==0, "invalid address leaked write data");
  };
  for (unsigned i=1; i<8; ++i) invalid(i);
  for (unsigned i=31; i<35; ++i) invalid(UINT64_C(1)<<i);
  invalid(UINT64_C(0x7ffffffff));
  dut.final();
  std::cout << "kernel DDR lane mapping: PASS\n";
}
