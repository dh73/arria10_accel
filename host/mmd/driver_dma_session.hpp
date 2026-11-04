#pragma once
#include "driver_dma_copy.hpp"
#include "driver_byte_copy.hpp"
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
  bool pending() const noexcept {return bool(operation_)||bool(copy_)||bool(byte_)||bool(byte_copy_);}
  bool attention() const noexcept {return attention_;}
  // Caller has qualified the readback ABI and holds this mailbox/context for
  // the session lifetime. Configure once before submissions; never reset the
  // sequence to recover unknown work. No discovery or driver admission here.
  bool configure_byte_writes(mailbox::Port& port,std::uint64_t base,
                             std::uint64_t aperture,std::uint32_t first_sequence) noexcept {
    if(pending()||attention_||byte_port_||!first_sequence)return false;
    byte_port_=&port;byte_base_=base;byte_aperture_=aperture;byte_sequence_=first_sequence;
    return true;
  }
  Submission submit(const Request& request,Completion completion) noexcept {
    if(pending()||attention_||!events_.valid())return Submission::NotAccepted;
    try {
      if((request.kind==Kind::Write || request.kind==Kind::Copy) && byte_port_){
        if(!completion)return Submission::NotAccepted;
        if(request.kind==Kind::Copy)
          byte_copy_=std::make_unique<DriverByteCopy>(fd_,*byte_port_,byte_base_,byte_aperture_,request,byte_sequence_,reader_,writer_);
        else
          byte_=std::make_unique<DriverByteWrite>(fd_,*byte_port_,byte_base_,byte_aperture_,
            request,byte_sequence_,reader_,writer_,memory::WriteCompletion::SelectedByteReadback);
        if(byte_state()==DriverByteWrite::State::Rejected){byte_.reset();byte_copy_.reset();return Submission::NotAccepted;}
        byte_completion_=std::move(completion);byte_ticket_=request.ticket;
        return Submission::Accepted; // Session owns the queued transfer now.
      }else if(request.kind==Kind::Copy)
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
  // Blocks on native DMA events. For configured masked writes, performs one
  // mailbox service transaction instead; caller supplies the native service
  // scheduling. No background polling thread is created by this class.
  Result wait_one() noexcept {
    if(attention_)return Result::Attention;
    if(!pending())return Result::Idle;
    if(byte_||byte_copy_)return service_byte();
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
    if(!attention_ || !pending() || byte_ || byte_copy_ || !events_.arm())return false;
    attention_=false;return true;
  }
  bool interrupt() noexcept {return events_.interrupt();}
 private:
  DriverByteWrite::State byte_state() const noexcept {return byte_?byte_->state():byte_copy_->state();}
  Result service_byte() noexcept {
    using S=DriverByteWrite::State;
    if(byte_state()==S::DmaPending){
      const auto event=events_.wait();
      if(event==AclPciDmaEvents::Event::Interrupted)return Result::Interrupted;
      if(event==AclPciDmaEvents::Event::Error){attention_=true;return Result::Attention;}
    }
    const auto state=byte_?byte_->advance():byte_copy_->advance();
    if(state==S::Attention){attention_=true;return Result::Attention;}
    if(state==S::DmaPending){
      // Level-triggered native readiness also covers completion before arm.
      if(!events_.arm()){attention_=true;return Result::Attention;}
      return Result::Retained;
    }
    if(!events_.disarm()){attention_=true;return Result::Attention;}
    if(state==S::Progress || state==S::MailboxPending)return Result::Retained;
    if(state!=S::Accepted && state!=S::Failed){attention_=true;return Result::Attention;}
    const int dma_result=byte_?byte_->dma_result():byte_copy_->dma_result();
    const int result=state==S::Accepted?0:(dma_result?dma_result:-EIO);
    if(state==S::Accepted){
      const auto next=std::uint64_t(byte_sequence_)+(byte_?byte_->sequence_count():byte_copy_->sequence_count());
      byte_sequence_=next>0xffffffffULL?0:std::uint32_t(next);
    }else attention_=true; // Partial sequence consumption forbids another request.
    // Each masked command has readback evidence; bulk uses exact driver drain.
    // These are per-operation completion facts, not global shutdown fences.
    try{byte_completion_(byte_ticket_,result,dma::DrainEvidence::PerOperation);}
    catch(...){attention_=true;return Result::Attention;}
    byte_.reset();byte_copy_.reset();byte_completion_={};return Result::Delivered;
  }
  int fd_;DmaReceiptRead reader_,writer_;AclPciDmaEvents events_;
  std::unique_ptr<DriverDmaOperation> operation_;std::unique_ptr<DriverDmaCopy> copy_;
  bool attention_{false};
  mailbox::Port* byte_port_{nullptr};std::uint64_t byte_base_{0},byte_aperture_{0};
  std::uint32_t byte_sequence_{0};dma::Ticket byte_ticket_{};Completion byte_completion_;
  std::unique_ptr<DriverByteWrite> byte_;std::unique_ptr<DriverByteCopy> byte_copy_;
};
}
