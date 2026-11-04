#include "aclpci_startup_client.hpp"
#include "pcie_linux_driver_exports.h"
#include <cassert>
#include <cerrno>
#include <iostream>
using C=asus::a10::AclPciStartupClient;
using S=C::State;
unsigned calls;ssize_t response;
ssize_t io(int fd,void* p,std::size_t n,bool reading) noexcept {
 ++calls;auto& c=*static_cast<acl_cmd*>(p);
 assert(fd==91 && n==sizeof c && c.bar_id==ACLPCI_CMD_BAR && c.command==ACLPCI_CMD_STARTUP);
 assert(c.size==40 && !c.device_addr && !c.is_diff_endian);
 auto w=static_cast<std::uint32_t*>(c.user_addr);
 assert(w[0]==1 && w[1]==(reading?2u:1u));
 if(reading){for(unsigned i=2;i<10;++i)assert(!w[i]);}
 else {for(unsigned i=0;i<6;++i)assert(w[i+2]==i+1);assert(w[8]==7 && w[9]==8);}
 errno=EINTR;return response;
}
int main(){
 const std::array<std::uint32_t,6> ctx{1,2,3,4,5,6};
 for(ssize_t code: {-1,0,1,2,40}){
  calls=0;response=code;C c(91,io);assert(c.advance()==S::Idle && !calls);
  auto expected=code==0?S::Pending:S::Unknown;
  assert(c.arm(ctx,0x800000007ULL)==expected && calls==1);
  assert(c.arm(ctx,0x800000007ULL)==expected && calls==1);
  if(code!=0){assert(c.advance()==S::Unknown && calls==1);}
 }
 for(ssize_t code: {-1,0,1,2,40}){
  calls=0;response=0;C c(91,io);assert(c.arm(ctx,0x800000007ULL)==S::Pending);
  response=code;auto expected=code==0?S::Pending:code==1?S::Accepted:code==2?S::Rejected:S::Unknown;
  assert(c.advance()==expected && calls==2);
  if(code!=0){assert(c.advance()==expected && calls==2);assert(c.arm(ctx,7)==expected && calls==2);}
 }
 calls=0;C invalid(-1,io),nullcall(91,nullptr),zero(91,io);
 assert(invalid.arm(ctx,7)==S::Invalid && nullcall.advance()==S::Invalid);
 assert(zero.arm(ctx,0)==S::Invalid && !calls);
 std::cout<<"STARTUP_CLIENT_PASS framing pending terminal ambiguity no_replay\n";
}
