#pragma once
#include "driver_byte_write.hpp"
#include <algorithm>
#include <cerrno>
namespace asus::a10::mmd {
// Capture the complete source before any destination write, including overlap.
// Retain this object until drain; Attention never authorizes disposal or retry.
class DriverByteCopy final {
 public:
  using State=DriverByteWrite::State;
  DriverByteCopy(int fd,mailbox::Port& port,std::uint64_t base,std::uint64_t aperture,
                Request request,std::uint32_t sequence,
                DmaReceiptRead reader=nullptr,DmaReceiptRead writer=nullptr)
    :fd_(fd),port_(port),base_(base),aperture_(aperture),request_(request),sequence_(sequence),
     reader_(reader),writer_(writer) {
    if(request.kind!=Kind::Copy || !request.size || aperture<4 || aperture>0x80000000ULL ||
       (aperture&3) || request.source_offset>aperture || request.destination_offset>aperture ||
       request.size>aperture-request.source_offset || request.size>aperture-request.destination_offset){
      state_=State::Rejected;return;
    }
    const auto head=(request.destination_offset&3)?
      std::min(request.size,std::size_t(4-(request.destination_offset&3))):0;
    sequences_=unsigned(head!=0)+unsigned(((request.size-head)&3)!=0);
    if(sequences_ && (!sequence || sequence>0xffffffffu-(sequences_-1))){state_=State::Rejected;return;}
    storage_.resize(request.size);
    auto r=request;r.kind=Kind::Read;r.staging=storage_.data();
    read_=std::make_unique<DriverDmaOperation>(fd,r,
      [this](dma::Ticket,int result,dma::DrainEvidence){result_=result;},reader,writer);
  }
  DriverByteCopy(const DriverByteCopy&)=delete;
  DriverByteCopy& operator=(const DriverByteCopy&)=delete;
  State state()const noexcept{return state_;}
  unsigned sequence_count()const noexcept{return sequences_;}
  int dma_result()const noexcept{return result_?result_:(write_?write_->dma_result():0);}
  State advance()noexcept {
    if(state_==State::Rejected||state_==State::Failed||state_==State::Attention||state_==State::Accepted)return state_;
    if(write_)return state_=write_->advance();
    if(!submitted_){
      submitted_=true;
      if(read_->submit()==Submission::NotAccepted)return state_=State::Failed;
      return state_=State::DmaPending;
    }
    auto result=read_->service();
    if(result==DriverDmaOperation::Service::Retained)return state_=State::DmaPending;
    if(result!=DriverDmaOperation::Service::Delivered)return state_=State::Attention;
    if(result_)return state_=State::Failed;
    // Build edge snapshots and aligned staging only after the source is drained.
    // Allocation failure here is safe: the read is finished, no write submitted.
    try{
      auto r=request_;r.kind=Kind::Write;r.staging=storage_.data();
      write_=std::make_unique<DriverByteWrite>(fd_,port_,base_,aperture_,r,sequence_,
        reader_,writer_,memory::WriteCompletion::SelectedByteReadback);
    }catch(...){result_=-ENOMEM;return state_=State::Failed;}
    if(write_->state()==State::Rejected){result_=-EINVAL;return state_=State::Failed;}
    return state_=State::Progress;
  }
 private:
  int fd_;mailbox::Port& port_;std::uint64_t base_,aperture_;Request request_;std::uint32_t sequence_;
  DmaReceiptRead reader_,writer_;std::vector<unsigned char> storage_;
  std::unique_ptr<DriverDmaOperation> read_;std::unique_ptr<DriverByteWrite> write_;
  unsigned sequences_{0};int result_{0};bool submitted_{false};State state_{State::Progress};
};
}
