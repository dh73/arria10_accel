#pragma once
#include "driver_dma_operation.hpp"
#include "ddr_byte_write.hpp"
#include "ddr_write_plan.hpp"
#include <memory>

namespace asus::a10::mmd {
// Transfer phase on a qualified, exclusively owned FD/mailbox/context. All
// allocations occur before hardware use. Keep this object and source staging
// until terminal, including Attention. No automatic retry or reset recovery.
// Accepted combines the explicitly selected mailbox completion semantics with
// DMA retirement. BackendAcceptance alone does not establish edge visibility;
// the MMD session requires SelectedByteReadback. Neither is a global host fence.
class DriverByteWrite final {
 public:
  enum class State { Progress, MailboxPending, DmaPending, Accepted,
                     Rejected, Failed, Attention };
  DriverByteWrite(int fd, mailbox::Port& port, std::uint64_t base,
                  std::uint64_t aperture, Request request,
                  std::uint32_t first_sequence,
                  DmaReceiptRead reader=nullptr,DmaReceiptRead writer=nullptr,
                  memory::WriteCompletion completion=memory::WriteCompletion::BackendAcceptance)
    :plan_(memory::plan_write(aperture,request.destination_offset,
                             request.staging,request.size)) {
    if(request.kind!=Kind::Write || !plan_.valid || !request.size){
      state_=State::Rejected;return;
    }
    for(std::size_t i=0;i<plan_.count;++i)
      if(plan_.segments[i].route==memory::WriteRoute::MaskedWord)++sequences_;
    if(sequences_ && (!first_sequence ||
       first_sequence>std::numeric_limits<std::uint32_t>::max()-(sequences_-1))){
      state_=State::Rejected;return;
    }
    unsigned edge=0;
    for(std::size_t i=0;i<plan_.count;++i){
      const auto& s=plan_.segments[i];
      if(s.route==memory::WriteRoute::MaskedWord){
        words_[i]=std::make_unique<memory::ByteWrite>(port,base,aperture,
          s.device_address,s.data,s.mask,first_sequence+edge++,completion);
        if(words_[i]->state()==memory::WriteState::Rejected)state_=State::Rejected;
      }else{
        auto bulk=request;bulk.size=s.bytes;bulk.destination_offset=s.device_address;
        bulk.staging=static_cast<unsigned char*>(request.staging)+s.source_offset;
        dma_=std::make_unique<DriverDmaOperation>(fd,bulk,
          [this](dma::Ticket,int result,dma::DrainEvidence){dma_result_=result;},reader,writer);
      }
    }
  }
  DriverByteWrite(const DriverByteWrite&)=delete;
  DriverByteWrite& operator=(const DriverByteWrite&)=delete;
  State state() const noexcept{return state_;}
  unsigned sequence_count() const noexcept{return sequences_;}
  int dma_result() const noexcept{return dma_result_;}
  // No loop or timer. Service DMA only on its completion event, and mailbox
  // pending status through the owning native device service path.
  State advance() noexcept {
    if(state_==State::Rejected||state_==State::Failed||state_==State::Attention||
       state_==State::Accepted)return state_;
    if(words_[index_]){
      switch(words_[index_]->advance()){
        case memory::WriteState::Progress:return state_=State::Progress;
        case memory::WriteState::AwaitingCompletion:return state_=State::MailboxPending;
        case memory::WriteState::Unknown:return state_=State::Attention;
        case memory::WriteState::Rejected:return state_=State::Failed;
        case memory::WriteState::Complete:break;
      }
    }else{
      if(!dma_submitted_){
        dma_submitted_=true;
        const auto result=dma_->submit();
        if(result==Submission::NotAccepted)return state_=State::Failed;
        // An uncertain syscall is never repeated; its exact receipt still
        // supplies the only possible retirement evidence.
        return state_=State::DmaPending;
      }
      const auto result=dma_->service();
      if(result==DriverDmaOperation::Service::Retained)return state_=State::DmaPending;
      if(result!=DriverDmaOperation::Service::Delivered)return state_=State::Attention;
      if(dma_result_)return state_=State::Failed;
    }
    return state_=++index_==plan_.count?State::Accepted:State::Progress;
  }
 private:
  memory::WritePlan plan_;
  std::array<std::unique_ptr<memory::ByteWrite>,3> words_;
  std::unique_ptr<DriverDmaOperation> dma_;
  std::size_t index_{0};unsigned sequences_{0};int dma_result_{0};
  bool dma_submitted_{false};State state_{State::Progress};
};
}
