// SPDX-License-Identifier: BSD-3-Clause
#include "../../apps/sycl/streaming_buffer_contract.hpp"
#include <cassert>
#include <limits>
using a10_streaming_contract::require_disjoint;
bool accepts(std::uintptr_t a, std::uintptr_t b, std::uint32_t n) {
  try { require_disjoint(a, b, n); return true; }
  catch (const std::invalid_argument&) { return false; }
}
int main() {
  for (std::uintptr_t a=1; a<128; ++a)
    for (std::uintptr_t b=1; b<128; ++b)
      for (std::uint32_t n=0; n<32; ++n) {
        bool overlap=false;
        for (unsigned i=0; i<4*n; ++i)
          overlap |= (a+i>=b && a+i<b+4*n);
        assert(accepts(a,b,n)==!overlap);
      }
  const auto max=std::numeric_limits<std::uintptr_t>::max();
  assert(!accepts(max-2,64,1));
  assert(!accepts(64,max-2,1));
  assert(!accepts(0,64,1));
  assert(!accepts(64,0,1));
  assert(accepts(0,0,0));
  assert(accepts(64,128,16));
  assert(!accepts(64,127,16));
}
