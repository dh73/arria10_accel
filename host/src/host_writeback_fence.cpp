#include "host_writeback_fence.hpp"
#include <limits>
namespace asus::a10::writeback {
Fence::Fence(mailbox::Port& p,std::uint64_t base,
             std::array<std::uint32_t,6> context) noexcept
 :port_(p),base_(base),context_(context) {
 if((base&3) || base>std::numeric_limits<std::uint64_t>::max()-31 ||
    !(context[0]|context[1]) || !(context[2]|context[3]|context[4]|context[5]))
  state_=State::Poisoned;
}
State Fence::advance() noexcept {
 if(state_!=State::Pending)return state_;
 mailbox::Reply r{mailbox::Outcome::Unknown};
 switch(step_) {
  case Step::Ready:case Step::Recheck:case Step::Confirm:
   r=port_.read32(base_);break;
  case Step::Context:r=port_.read32(base_+4+4*index_);break;
  case Step::Echo:r=port_.write32(base_+4+4*index_,context_[index_]);break;
  case Step::Flush:r=port_.fence();break;
  case Step::Commit:r=port_.write32(base_+28,0xa10f0001);break;
 }
 // Even NotIssued ends this attempt; never recycle staged context implicitly.
 if(r.outcome!=mailbox::Outcome::Completed)return state_=State::Poisoned;
 switch(step_) {
  case Step::Ready:
   if(r.value==0)break;
   if(r.value!=1)return state_=State::Poisoned;
   step_=Step::Context;break;
  case Step::Context:
   if(r.value!=context_[index_])return state_=State::Poisoned;
   if(++index_==6){index_=0;step_=Step::Recheck;}break;
  case Step::Recheck:
   if(r.value!=1)return state_=State::Poisoned;
   step_=Step::Echo;break;
  case Step::Echo:if(++index_==6)step_=Step::Flush;break;
  case Step::Flush:step_=Step::Commit;break;
  case Step::Commit:step_=Step::Confirm;break;
  case Step::Confirm:
   if(r.value==3)state_=State::Settled;
   else if(r.value!=1)state_=State::Poisoned;
   break;
 }
 return state_;
}
}
