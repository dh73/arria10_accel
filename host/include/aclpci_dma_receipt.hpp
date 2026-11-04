#pragma once
#include <cstddef>
#include <cstdint>
#include <sys/types.h>
namespace asus::a10 {
enum class DmaReceiptState { Unknown, None, Pending, Drained };
struct DmaReceipt {
  DmaReceiptState state{DmaReceiptState::Unknown};
  std::uint64_t submitted{0}, completed{0};
  std::int32_t result{0};
  // expected=0 is discovery only, never buffer retirement authority.
  bool releases_buffers(std::uint64_t expected) const noexcept {
    return expected && state==DmaReceiptState::Drained &&
      submitted==expected && completed==expected && result<=0;
  }
};
using DmaReceiptRead = ssize_t (*)(int, void*, std::size_t);
// Borrowed, exclusively managed driver FD; caller serializes submission/query.
// Exactly one syscall, normally on a completion event. No replay or ownership
// release on I/O/malformed-receipt errors. Does not certify shared-table drain.
DmaReceipt read_dma_receipt(int fd, std::uint64_t expected,
                           DmaReceiptRead reader=nullptr) noexcept;
}
