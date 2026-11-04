#include "ddr_snapshot_reader.hpp"
#include <limits>
namespace asus::a10::metrics {
Capture::Capture(mailbox::Port& p,std::uint64_t base,std::array<std::uint64_t,4> context)noexcept:port_(p),base_(base){
 sample_.context=context;
 if((base&3)||base>std::numeric_limits<std::uint64_t>::max()-79||context==std::array<std::uint64_t,4>{})state_=CaptureState::Rejected;
}
CaptureState Capture::advance()noexcept{
 if(state_!=CaptureState::Pending)return state_;
 mailbox::Reply r{mailbox::Outcome::Unknown};
 switch(step_){
  case Step::Magic:r=port_.read32(base_);break;
  case Step::Command:r=port_.write32(base_,0xa10d0001);break;
  case Step::Fence:r=port_.fence();break;
  case Step::BeforeHi:case Step::BeforeCheck:case Step::AfterHi:case Step::AfterCheck:r=port_.read32(base_+12);break;
  case Step::BeforeLo:case Step::AfterLo:r=port_.read32(base_+8);break;
  case Step::Flags:r=port_.read32(base_+4);break;
  case Step::Counts:r=port_.read32(base_+16+word_*4);break;
 }
 if(r.outcome!=mailbox::Outcome::Completed)return state_=CaptureState::Poisoned;
 switch(step_){
  case Step::Magic:if(r.value!=0xa10d0001)return state_=CaptureState::Rejected;step_=Step::Command;break;
  case Step::Command:step_=Step::Fence;break;
  case Step::Fence:step_=Step::BeforeHi;break;
  case Step::BeforeHi:before_=std::uint64_t(r.value)<<32;step_=Step::BeforeLo;break;
  case Step::BeforeLo:before_|=r.value;step_=Step::BeforeCheck;break;
  case Step::BeforeCheck:
   if(!before_||r.value!=(before_>>32))return state_=CaptureState::Rejected;
   step_=Step::Flags;break;
  case Step::Flags:
   if(r.value!=1)return state_=CaptureState::Rejected;
   sample_.valid=true;step_=Step::Counts;break;
  case Step::Counts:
   sample_.counts[word_/2]|=std::uint64_t(r.value)<<((word_%2)*32);
   if(++word_==14)step_=Step::AfterHi;
   break;
  case Step::AfterHi:after_=std::uint64_t(r.value)<<32;step_=Step::AfterLo;break;
  case Step::AfterLo:after_|=r.value;step_=Step::AfterCheck;break;
  case Step::AfterCheck:
   if(r.value!=(after_>>32)||after_!=before_)return state_=CaptureState::Rejected;
   sample_.sequence=after_;state_=CaptureState::Complete;break;
 }
 return state_;
}
}
