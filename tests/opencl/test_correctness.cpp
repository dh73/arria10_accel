#include "asus_a10/workload_reference.hpp"
#include <array>
#include <cstdint>
#include <iostream>
#include <vector>
extern "C" void correctness_pass1(const std::uint32_t*, const std::uint32_t*,
                                  std::uint32_t*, std::uint32_t);
extern "C" void correctness_pass2(const std::uint32_t*, const std::uint32_t*,
                                  std::uint32_t*, std::uint32_t);
int main() {
  constexpr std::uint32_t sentinel = 0xa5a5a5a5U;
  constexpr std::array<std::uint32_t, 8> counts{0,1,3,17,257,4093,65537,1000003};
  std::uint32_t state = 0x6d2b79f5U;
  auto random = [&]() { state ^= state << 13; state ^= state >> 17;
                       state ^= state << 5; return state; };
  for (auto n : counts) {
    std::vector<std::uint32_t> a(n+2), b(n+2), temp(n+2,sentinel), out(n+2,sentinel);
    for (std::uint32_t i=0;i<n;++i) {
      a[i+1] = i % 7 == 0 ? 0xffffffffU : random();
      b[i+1] = i % 11 == 0 ? 0x80000000U : random();
    }
    auto original_a=a, original_b=b;
    correctness_pass1(a.data()+1,b.data()+1,temp.data()+1,n);
    correctness_pass2(temp.data()+1,b.data()+1,out.data()+1,n);
    if (a!=original_a || b!=original_b || temp.front()!=sentinel ||
        temp.back()!=sentinel || out.front()!=sentinel || out.back()!=sentinel) return 2;
    for (std::uint32_t i=0;i<n;++i) {
      if (out[i+1] != asus_a10::workload_reference(a[i+1],b[i+1],i)) {
        std::cerr << "Mismatch count=" << n << " index=" << i << '\n'; return 1;
      }
    }
    std::cout << "OPENCL_BODY_HOST_PASS count=" << n << '\n';
  }
}
