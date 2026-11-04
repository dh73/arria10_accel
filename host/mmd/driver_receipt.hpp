#pragma once
#include "adapter.hpp"
#include "aclpci_dma_receipt.hpp"
#include <utility>
namespace asus::a10::mmd {
// One accepted driver request on an exclusively managed file lifetime. Construct
// before submission, retain through uncertain I/O, and feed only receipts read
// from that same FD. The driver generation and MMD ticket are separate domains.
// This gate neither submits DMA nor grants image qualification/admission.
class DriverReceiptCompletion {
 public:
  enum class Result { Retained, Delivered, AlreadyDelivered, CallbackFailed };
  DriverReceiptCompletion(std::uint64_t generation, dma::Ticket ticket, Completion callback)
    : generation_(generation), ticket_(ticket), callback_(std::move(callback)) {}
  DriverReceiptCompletion(const DriverReceiptCompletion&)=delete;
  DriverReceiptCompletion& operator=(const DriverReceiptCompletion&)=delete;
  // Caller serializes event service. No polling and no callback retry.
  Result observe(const DmaReceipt& receipt) noexcept {
    if(delivered_) return failed_?Result::CallbackFailed:Result::AlreadyDelivered;
    if(!callback_ || !receipt.releases_buffers(generation_)) return Result::Retained;
    delivered_=true; // Fence reentrant/duplicate events before invoking callback.
    try { callback_(ticket_,receipt.result,dma::DrainEvidence::PerOperation); }
    catch(...) { failed_=true;return Result::CallbackFailed; }
    return Result::Delivered;
  }
 private:
  const std::uint64_t generation_;
  const dma::Ticket ticket_;
  Completion callback_;
  bool delivered_{false}, failed_{false};
};
}
