#pragma once
#include "driver_dma_copy.hpp"
#include "aclpci_dma_events.hpp"
#include <memory>
namespace asus::a10::mmd {
// Serial operation/event owner on an already qualified exclusive driver FD.
// Transport retains this session and staging while pending(), including errors
// and interruption. No discovery, admission, FD closure or detached thread here.
// submit/wait_one/pending require external serialization; only interrupt may
// run concurrently. The transport joins its waiter before destroying a session.
class DriverDmaSession {
 public:
  enum class Result { Idle, Retained, Delivered, Interrupted, Attention };
  DriverDmaSession(int fd,DmaReceiptRead reader=nullptr,DmaReceiptRead writer=nullptr)
    : fd_(fd),reader_(reader),writer_(writer),events_(fd) {}
  bool pending() const noexcept {return bool(operation_)||bool(copy_);}
  bool attention() const noexcept {return attention_;}
  Submission submit(const Request& request,Completion completion) noexcept {
    if(pending()||attention_||!events_.valid())return Submission::NotAccepted;
    try {
      if(request.kind==Kind::Copy)
        copy_=std::make_unique<DriverDmaCopy>(fd_,request,std::move(completion),reader_,writer_);
      else
        operation_=std::make_unique<DriverDmaOperation>(fd_,request,std::move(completion),reader_,writer_);
    }catch(...) {return Submission::NotAccepted;} // Nothing submitted yet.
    // Register before submission: even an immediate completion is observable.
    if(!events_.arm()){operation_.reset();copy_.reset();attention_=true;return Submission::NotAccepted;}
    auto outcome=copy_?copy_->submit():operation_->submit();
    if(outcome==Submission::NotAccepted){
      attention_=!events_.disarm();operation_.reset();copy_.reset();
    }
    return outcome;
  }
  Result wait_one() noexcept {
    if(attention_)return Result::Attention;
    if(!pending())return Result::Idle;
    const auto event=events_.wait();
    if(event==AclPciDmaEvents::Event::Interrupted)return Result::Interrupted;
    if(event==AclPciDmaEvents::Event::Error){attention_=true;return Result::Attention;}
    auto result=copy_?copy_->service():operation_->service();
    if(result==DriverDmaOperation::Service::Delivered){
      if(!events_.disarm()){attention_=true;return Result::Attention;}
      operation_.reset();copy_.reset();return Result::Delivered;
    }
    if(result==DriverDmaOperation::Service::CallbackFailed ||
       result==DriverDmaOperation::Service::Attention){attention_=true;return Result::Attention;}
    // Stale readiness or a staged copy's newly submitted write: rearm once.
    // Native level readiness closes the completion-before-rearm race.
    if(!events_.arm()){attention_=true;return Result::Attention;}
    return Result::Retained;
  }
  // Explicit intervention boundary after the caller resolves an event/receipt
  // failure. Never invoke repeatedly as a status check or replay submission.
  bool resume_events() noexcept {
    if(!attention_ || !pending() || !events_.arm())return false;
    attention_=false;return true;
  }
  bool interrupt() noexcept {return events_.interrupt();}
 private:
  int fd_;DmaReceiptRead reader_,writer_;AclPciDmaEvents events_;
  std::unique_ptr<DriverDmaOperation> operation_;std::unique_ptr<DriverDmaCopy> copy_;
  bool attention_{false};
};
}
