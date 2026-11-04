#include "aclpci_mailbox_port.hpp"
#include "pcie_linux_driver_exports.h"
#include <cstdint>
#include <cstdio>
#include <stdexcept>
using namespace asus::a10::mailbox;
extern "C" int mailbox_put(unsigned long long,unsigned int);
extern "C" int mailbox_get(unsigned long long,unsigned int*);
static constexpr std::uint64_t base=0x100000000ull;
static bool lose_command_ack=false;
static unsigned calls=0;
static ssize_t driver_call(int fd,void* packet,std::size_t n,bool reading) noexcept {
 ++calls; auto& cmd=*static_cast<acl_cmd*>(packet);
 if(fd!=91 || n!=4 || cmd.size!=4 || cmd.bar_id!=2 || cmd.command!=ACLPCI_CMD_DEFAULT || cmd.is_diff_endian!=0) return -1;
 auto address=static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(cmd.device_addr));
 auto* value=static_cast<std::uint32_t*>(cmd.user_addr);
 if(reading) return mailbox_get(address,value)==0?0:-1;
 if(mailbox_put(address,*value))return -1;
 if(lose_command_ack && address==base+16)return -1;
 return 0;
}
void require(bool b) { if(!b)throw std::runtime_error("host/RTL mailbox mismatch"); }
void complete(Sequencer& s) {
 // Native simulation service loop; all device calls advance the SV clocks.
 while(s.state()==State::Pending)s.advance();
 require(s.state()==State::Completed);
}
extern "C" int run_mailbox_host(int* result) {
 *result=1;
 try {
  AclPciPort p(91,base,driver_call);Sequencer s(p,base);
  require(s.begin(1,128,false,0xaabbccddeeff0011ull,0x35));complete(s);
  require(s.begin(2,128,true));complete(s);require(s.value()==0x1122ccdd55ff7711ull);
  require(s.begin(3,128,true));complete(s);require(s.value()==0);
  auto n=calls;s.advance();require(calls==n);require(!s.begin(3,128,true));
  lose_command_ack=true;
  require(s.begin(4,8,false,1));
  while(s.state()==State::Pending)s.advance();
  require(s.state()==State::Poisoned);n=calls;s.advance();
  require(calls==n && !s.begin(5,8,false,1));
  *result=0;
 }catch(const std::exception& e){std::fprintf(stderr,"MAILBOX_HOST_RTL_FAILURE %s\n",e.what());}
 return 0;
}
