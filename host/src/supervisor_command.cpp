#include "supervisor_command.hpp"
#include <limits>
namespace asus::a10::control {
Request::Request(mailbox::Port& p,std::uint64_t base,std::uint64_t id,Command c) noexcept
 :port_(p),base_(base),id_(id),command_(c){
 if(!id || (base&3) || base>std::numeric_limits<std::uint64_t>::max()-31 || std::uint32_t(c)>2)
  state_=State::Poisoned;
}
State Request::advance() noexcept {
 if(state_!=State::Pending)return state_;
 mailbox::Reply r{mailbox::Outcome::Unknown};
 switch(step_){
  case Step::Ready:case Step::Status:r=port_.read32(base_+16);break;
  case Step::PreviousLow:case Step::ResultLow:r=port_.read32(base_+24);break;
  case Step::PreviousHigh:case Step::ResultHigh:r=port_.read32(base_+28);break;
  case Step::IdLow:r=port_.write32(base_,std::uint32_t(id_));break;
  case Step::IdHigh:r=port_.write32(base_+4,std::uint32_t(id_>>32));break;
  case Step::Op:r=port_.write32(base_+8,std::uint32_t(command_));break;
  case Step::Flush:r=port_.fence();break;
  case Step::Commit:r=port_.write32(base_+12,0xa10c0001);break;
  case Step::Reason:r=port_.read32(base_+20);break;
 }
 if(r.outcome!=mailbox::Outcome::Completed)return state_=State::Poisoned;
 switch(step_){
  case Step::Ready:
   if(r.value==1)break;
   if(r.value!=0&&r.value!=2&&r.value!=6)return state_=State::Poisoned;
   step_=Step::PreviousLow;break;
  case Step::PreviousLow:previous_=r.value;step_=Step::PreviousHigh;break;
  case Step::PreviousHigh:
   previous_|=std::uint64_t(r.value)<<32;
   if(id_<=previous_)return state_=State::Poisoned;
   step_=Step::IdLow;break;
  case Step::IdLow:step_=Step::IdHigh;break;
  case Step::IdHigh:step_=Step::Op;break;
  case Step::Op:step_=Step::Flush;break;
  case Step::Flush:step_=Step::Commit;break;
  case Step::Commit:step_=Step::Status;break;
  case Step::Status:
   if(r.value==1)break;
   if(r.value!=2&&r.value!=6)return state_=State::Poisoned;
   accepted_=r.value==6;step_=Step::ResultLow;break;
  case Step::ResultLow:result_=r.value;step_=Step::ResultHigh;break;
  case Step::ResultHigh:
   result_|=std::uint64_t(r.value)<<32;
   if(result_!=id_)return state_=State::Poisoned;
   step_=Step::Reason;break;
  case Step::Reason:
   if(r.value>7 || accepted_!=(r.value==0))return state_=State::Poisoned;
   reason_=r.value;state_=accepted_?State::Accepted:State::Rejected;break;
 }
 return state_;
}
}
