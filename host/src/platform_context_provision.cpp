#include "platform_context_provision.hpp"
#include <limits>
namespace asus::a10::context {
Provision::Provision(mailbox::Port& p,std::uint64_t base,std::uint64_t epoch,
                     std::array<std::uint64_t,2> session)noexcept:port_(p),base_(base){
 if((base&3)||base>std::numeric_limits<std::uint64_t>::max()-31||!epoch||(!session[0]&&!session[1]))state_=State::Rejected;
 const std::array<std::uint64_t,3> values{epoch,session[0],session[1]};
 for(unsigned i=0;i<3;++i){words_[2*i]=std::uint32_t(values[i]);words_[2*i+1]=std::uint32_t(values[i]>>32);}
}
State Provision::advance()noexcept{
 if(state_!=State::Pending)return state_;
 mailbox::Reply r{mailbox::Outcome::Unknown};
 if(step_==0)r=port_.read32(base_);
 else if(step_==1||step_==11||step_==18)r=port_.read32(base_+4);
 else if(step_<=7)r=port_.write32(base_+8+4*(step_-2),words_[step_-2]);
 else if(step_==8||step_==10)r=port_.fence();
 else if(step_==9)r=port_.write32(base_,0xa10e0001);
 else r=port_.read32(base_+8+4*(step_-12));
 if(r.outcome!=mailbox::Outcome::Completed)return state_=State::Poisoned;
 if((step_==0&&r.value!=0xa10e0001)||(step_==1&&r.value!=0)||
    ((step_==11||step_==18)&&r.value!=1)||
    (step_>=12&&step_<=17&&r.value!=words_[step_-12]))return state_=State::Rejected;
 if(step_++==18)state_=State::Complete;
 return state_;
}
}
