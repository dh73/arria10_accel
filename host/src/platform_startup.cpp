#include "platform_startup.hpp"
namespace asus::a10::control {
Startup::Startup(mailbox::Port& p,std::uint64_t pb,mailbox::Port& f,std::uint64_t fb,
                 mailbox::Port& c,std::uint64_t cb,std::uint64_t epoch,
                 std::array<std::uint64_t,2> session,std::uint64_t id)noexcept
 :provision_(p,pb,epoch,session),
  open_(f,fb,c,cb,{std::uint32_t(epoch),std::uint32_t(epoch>>32),
         std::uint32_t(session[0]),std::uint32_t(session[0]>>32),
         std::uint32_t(session[1]),std::uint32_t(session[1]>>32)},1,id,Command::Start){
 if(provision_.state()!=context::State::Pending)state_=State::Rejected;
 if(open_.state()!=State::Pending)state_=State::Poisoned;
}
State Startup::advance()noexcept{
 if(state_!=State::Pending)return state_;
 if(!provisioned_){
  switch(provision_.advance()){
   case context::State::Pending:break;
   case context::State::Complete:provisioned_=true;break;
   case context::State::Rejected:state_=State::Rejected;break;
   case context::State::Poisoned:state_=State::Poisoned;break;
  }
  return state_;
 }
 return state_=open_.advance();
}
}
