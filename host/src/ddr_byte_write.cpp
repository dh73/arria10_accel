#include "ddr_byte_write.hpp"
#include <limits>
namespace asus::a10::memory {
ByteWrite::ByteWrite(mailbox::Port& p,std::uint64_t base,std::uint64_t bytes,
 std::uint64_t address,std::uint32_t data,std::uint8_t mask,std::uint32_t sequence) noexcept
 :port_(p),base_(base),address_(address),data_(data),sequence_(sequence),mask_(mask){
 if((base&3)||base>std::numeric_limits<std::uint64_t>::max()-35||
    bytes<4||bytes>0x80000000ULL||(bytes&3)||(address&3)||address>bytes-4||
    !mask||(mask&0xf0)||!sequence)state_=WriteState::Rejected;
}
WriteState ByteWrite::advance() noexcept {
 if(state_!=WriteState::Progress&&state_!=WriteState::AwaitingCompletion)return state_;
 mailbox::Reply reply{mailbox::Outcome::Unknown};
 switch(step_){
  case 0:reply=port_.read32(base_);break;
  case 1:case 11:reply=port_.read32(base_+4);break;
  case 2:case 12:reply=port_.read32(base_+32);break;
  case 3:reply=port_.write32(base_+8,std::uint32_t(address_));break;
  case 4:reply=port_.write32(base_+12,std::uint32_t(address_>>32));break;
  case 5:reply=port_.write32(base_+16,data_);break;
  case 6:reply=port_.write32(base_+20,mask_);break;
  case 7:reply=port_.write32(base_+24,sequence_);break;
  case 8:case 10:reply=port_.fence();break;
  case 9:attempted_=true;reply=port_.write32(base_+28,1);break;
  default:return state_=WriteState::Unknown;
 }
 if(reply.outcome!=mailbox::Outcome::Completed)return state_=WriteState::Unknown;
 if((step_==0&&reply.value!=0x42595701)||
    (step_==1&&reply.value!=(sequence_==1?0u:4u))||
    (step_==2&&reply.value!=sequence_-1))return state_=WriteState::Rejected;
 if(step_==11){
  if((reply.value&~7u)||(reply.value&2))return state_=WriteState::Unknown;
  if(reply.value&1)return state_=WriteState::AwaitingCompletion;
  if(!(reply.value&4))return state_=WriteState::Unknown;
 }
 if(step_==12)return state_=reply.value==sequence_?WriteState::Complete:WriteState::Unknown;
 ++step_;return state_=WriteState::Progress;
}
}
