#pragma once
#include "driver_dma_operation.hpp"
#include <cerrno>
#include <limits>
#include <vector>
namespace asus::a10::mmd {
// Host-staged copy on an exclusively owned qualified FD. The entire source is
// drained before destination submission, so overlapping ranges are supported.
// Construct before submission; retain this object until Delivered, including
// uncertain syscall outcomes. Events drive service; it never waits or polls.
class DriverDmaCopy {
 public:
  using Service=DriverDmaOperation::Service;
  DriverDmaCopy(int fd,Request request,Completion completion,
                DmaReceiptRead reader=nullptr,DmaReceiptRead writer=nullptr)
    : read_(fd,reader,writer),write_(fd,reader,writer),request_(request),
      completion_(std::move(completion)),storage_(request.size) {}
  DriverDmaCopy(const DriverDmaCopy&)=delete;
  DriverDmaCopy& operator=(const DriverDmaCopy&)=delete;
  Submission submit() noexcept {
    if(started_)return outcome_;
    started_=true;
    if(request_.kind!=Kind::Copy || !completion_ || !request_.size ||
       (request_.size&3) || (request_.source_offset&3) ||
       (request_.destination_offset&3) ||
       request_.size>std::size_t(std::numeric_limits<ssize_t>::max()) ||
       request_.size>std::numeric_limits<std::size_t>::max()-request_.source_offset ||
       request_.size>std::numeric_limits<std::size_t>::max()-request_.destination_offset)
      return outcome_=Submission::NotAccepted;
    auto state=read_.submit(storage_.data(),storage_.size(),request_.source_offset,true);
    outcome_=state==AclPciDmaClient::State::Pending?Submission::Accepted:
      read_.generation()?Submission::Indeterminate:Submission::NotAccepted;
    return outcome_;
  }
  Service service() noexcept {
    if(delivered_)return failed_?Service::CallbackFailed:Service::AlreadyDelivered;
    if(!started_ || outcome_==Submission::NotAccepted)return Service::Retained;
    if(!writing_){
      if(read_.advance()!=AclPciDmaClient::State::Drained)return Service::Retained;
      if(read_.result()!=0)return finish(read_.result());
      writing_=true; // Reserve second submission before entering the syscall.
      auto state=write_.submit(storage_.data(),storage_.size(),request_.destination_offset,false);
      if(!write_.generation())return finish(-EIO); // No write was attempted.
      (void)state;
      return Service::Retained;
    }
    if(write_.advance()!=AclPciDmaClient::State::Drained)return Service::Retained;
    return finish(write_.result());
  }
 private:
  Service finish(int result) noexcept {
    delivered_=true;
    try {completion_(request_.ticket,result,dma::DrainEvidence::PerOperation);}
    catch(...) {failed_=true;return Service::CallbackFailed;}
    return Service::Delivered;
  }
  AclPciDmaClient read_,write_;const Request request_;Completion completion_;
  std::vector<unsigned char> storage_;
  Submission outcome_{Submission::NotAccepted};
  bool started_{false},writing_{false},delivered_{false},failed_{false};
};
}
