#pragma once
#include "adapter.hpp"
#include "aclpci_dma_client.hpp"
#include <utility>
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
    : client_(fd,reader,writer), request_(request), completion_(std::move(completion)) {}
  DriverDmaOperation(const DriverDmaOperation&)=delete;
  DriverDmaOperation& operator=(const DriverDmaOperation&)=delete;
  Submission submit() noexcept {
    if(submitted_)return outcome_;
    submitted_=true;
    // Device-to-device copy requires its own ordered two-transfer implementation.
    if(!completion_ || (request_.kind!=Kind::Read && request_.kind!=Kind::Write) || !request_.staging || !request_.size)
      return outcome_=Submission::NotAccepted;
    auto state=client_.submit(request_.staging,request_.size,
      request_.kind==Kind::Read?request_.source_offset:request_.destination_offset,
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
    try {completion_(request_.ticket,client_.result(),dma::DrainEvidence::PerOperation);}
    catch(...) {failed_=true;return Service::CallbackFailed;}
    return Service::Delivered;
  }
 private:
  AclPciDmaClient client_;const Request request_;Completion completion_;
  Submission outcome_{Submission::NotAccepted};
  bool submitted_{false},delivered_{false},failed_{false};
};
}
