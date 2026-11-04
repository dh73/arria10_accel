#pragma once
#include "aclpci_dma_receipt.hpp"
namespace asus::a10 {
// One request per instance, borrowed exclusive FD. Caller retains the buffer
// until state()==Drained; destruction, errors and cancellation do not drain it.
// No other actor may submit through this file between snapshot and submission.
class AclPciDmaClient {
 public:
  enum class State { Idle, Invalid, Pending, Unknown, Drained };
  AclPciDmaClient(int fd,DmaReceiptRead reader=nullptr,DmaReceiptRead writer=nullptr) noexcept;
  AclPciDmaClient(const AclPciDmaClient&)=delete;
  AclPciDmaClient& operator=(const AclPciDmaClient&)=delete;
  State submit(void* buffer,std::size_t bytes,std::uint64_t address,bool reading) noexcept;
  State advance() noexcept; // one receipt read, on a completion/recovery event
  State state() const noexcept {return state_;}
  std::uint64_t generation() const noexcept {return generation_;}
  std::int32_t result() const noexcept {return result_;} // meaningful only Drained
 private:
  int fd_;DmaReceiptRead reader_,writer_;
  State state_;std::uint64_t generation_{0};std::int32_t result_{0};
};
}
