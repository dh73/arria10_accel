#pragma once
#include "adapter.hpp"
#include "aclpci_dma_client.hpp"
#include <utility>
#include <cstring>
#include <limits>
namespace asus::a10::mmd {
// Event-serviced operation on an already qualified, exclusively owned driver FD.
// Allocate this object and its callback before submit. The transport must keep
// it and adapter staging alive through uncertain acceptance, close and removal.
// Qualification, descriptor-file lifetime and IRQ dispatch belong to transport.
class DriverDmaOperation {
 public:
  enum class Service { Retained, Delivered, AlreadyDelivered, CallbackFailed, Attention };
  DriverDmaOperation(int fd, Request request, Completion completion,
                     DmaReceiptRead reader=nullptr,DmaReceiptRead writer=nullptr)
    : client_(fd,reader,writer), request_(request), completion_(std::move(completion)),
      dma_buffer_(request.staging),dma_bytes_(request.size),
      dma_address_(request.kind==Kind::Read?request.source_offset:request.destination_offset) {
    if(request.kind==Kind::Read && request.staging && request.size){
      const auto maximum=std::numeric_limits<std::size_t>::max();
      prefix_=request.source_offset&3;
      if(request.size>maximum-request.source_offset || request.size>maximum-prefix_-3){
        layout_valid_=false;return;
      }
      dma_bytes_=(request.size+prefix_+3)&~std::size_t(3);
      dma_address_=request.source_offset-prefix_;
      if(dma_bytes_>maximum-dma_address_ || dma_bytes_>std::size_t(std::numeric_limits<ssize_t>::max())){
        layout_valid_=false;return;
      }
      if(prefix_ || dma_bytes_!=request.size || (reinterpret_cast<std::uintptr_t>(request.staging)&3)){
        bounce_.resize(dma_bytes_);dma_buffer_=bounce_.data();
      }
    }
    if(request.kind==Kind::Write && request.staging && request.size){
      const auto maximum=std::numeric_limits<std::size_t>::max();
      if((dma_address_&3) || (dma_bytes_&3) || dma_bytes_>maximum-dma_address_ ||
         dma_bytes_>std::size_t(std::numeric_limits<ssize_t>::max())){
        layout_valid_=false;return;
      }
      // Stripping a masked head can leave bulk source staging unaligned.
      // Snapshot it before submission; never copy a write bounce back to source.
      if(reinterpret_cast<std::uintptr_t>(request.staging)&3){
        bounce_.resize(dma_bytes_);dma_buffer_=bounce_.data();
        std::memcpy(dma_buffer_,request.staging,dma_bytes_);
      }
    }
  }
  DriverDmaOperation(const DriverDmaOperation&)=delete;
  DriverDmaOperation& operator=(const DriverDmaOperation&)=delete;
  Submission submit() noexcept {
    if(submitted_)return outcome_;
    submitted_=true;
    // Device-to-device copy requires its own ordered two-transfer implementation.
    if(!layout_valid_ || !completion_ || (request_.kind!=Kind::Read && request_.kind!=Kind::Write) || !request_.staging || !request_.size)
      return outcome_=Submission::NotAccepted;
    auto state=client_.submit(dma_buffer_,dma_bytes_,dma_address_,
      request_.kind==Kind::Read);
    if(state==AclPciDmaClient::State::Pending)outcome_=Submission::Accepted;
    else if(state==AclPciDmaClient::State::Invalid || !client_.generation())outcome_=Submission::NotAccepted;
    else outcome_=Submission::Indeterminate;
    return outcome_;
  }
  Service service() noexcept {
    if(delivered_)return failed_?Service::CallbackFailed:Service::AlreadyDelivered;
    if(!submitted_ || outcome_==Submission::NotAccepted)return Service::Retained;
    auto state=client_.advance();
    if(state==AclPciDmaClient::State::Unknown)return Service::Attention;
    if(state!=AclPciDmaClient::State::Drained)return Service::Retained;
    delivered_=true;
    if(request_.kind==Kind::Read && !client_.result() && !bounce_.empty())
      std::memcpy(request_.staging,bounce_.data()+prefix_,request_.size);
    try {completion_(request_.ticket,client_.result(),dma::DrainEvidence::PerOperation);}
    catch(...) {failed_=true;return Service::CallbackFailed;}
    return Service::Delivered;
  }
 private:
  AclPciDmaClient client_;const Request request_;Completion completion_;
  std::vector<unsigned char> bounce_;
  void* dma_buffer_;std::size_t dma_bytes_,dma_address_,prefix_{0};
  bool layout_valid_{true};
  Submission outcome_{Submission::NotAccepted};
  bool submitted_{false},delivered_{false},failed_{false};
};
}
