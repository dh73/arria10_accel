#pragma once
#include "kernel_mailbox.hpp"
#include <array>
#include <cerrno>
extern "C" {
#include "aclpci_context_provision.h"
}
enum class KernelState { Pending,Complete,Rejected,Poisoned };
// Test transport only: kernel C state machine is linked unchanged as C.
class KernelProvision {
 asus::a10::mailbox::Port& port_;std::uint64_t base_;
 aclpci_context_provision request_{};
 static int read(void* p,unsigned off,u32* value){auto& s=*static_cast<KernelProvision*>(p);auto r=s.port_.read32(s.base_+off);*value=r.value;return r.outcome==asus::a10::mailbox::Outcome::Completed?0:-EIO;}
 static int write(void* p,unsigned off,u32 value){auto& s=*static_cast<KernelProvision*>(p);return s.port_.write32(s.base_+off,value).outcome==asus::a10::mailbox::Outcome::Completed?0:-EIO;}
 static int flush(void* p){return static_cast<KernelProvision*>(p)->port_.fence().outcome==asus::a10::mailbox::Outcome::Completed?0:-EIO;}
 public:
 KernelProvision(asus::a10::mailbox::Port& p,std::uint64_t base,std::uint64_t epoch,std::array<std::uint64_t,2> session):port_(p),base_(base){
  const u32 w[6]={u32(epoch),u32(epoch>>32),u32(session[0]),u32(session[0]>>32),u32(session[1]),u32(session[1]>>32)};
  aclpci_context_provision_init(&request_,w);
 }
 KernelState state()const{return request_.result==0?KernelState::Pending:request_.result==1?KernelState::Complete:KernelState::Poisoned;}
 KernelState advance(){const aclpci_fence_io io{this,read,write,flush};aclpci_context_provision_step(&request_,&io);return state();}
};
