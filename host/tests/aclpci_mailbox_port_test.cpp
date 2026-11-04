#include "aclpci_mailbox_port.hpp"
#include "pcie_linux_driver_exports.h"
#include <cassert>
#include <cerrno>
#include <iostream>
#include <vector>
#include <utility>
using namespace asus::a10::mailbox;
namespace {
unsigned calls, commands, fail_at; ssize_t failure;
std::uint32_t regs[8]{};
std::uint64_t cra=0x123456789abcdef0ull;
std::vector<std::pair<unsigned,std::uint32_t>> posted;
ssize_t io(int fd,void* ptr,std::size_t count,bool reading) noexcept {
 ++calls; auto& c=*static_cast<acl_cmd*>(ptr);
 assert(fd==91 && count==4 && c.size==4 && c.bar_id==2 && c.command==0 && c.is_diff_endian==0);
 auto a=reinterpret_cast<std::uintptr_t>(c.device_addr);
 assert(a>=0x1000 && a<0x1020 && !(a&3)); auto ix=(a-0x1000)/4;
 auto& val=*static_cast<std::uint32_t*>(c.user_addr);
 if(reading) {
  for(auto [i,v]:posted) {
   if(i!=4) regs[i]=v;
   else {++commands; regs[5]=2;
    if(v==2) {regs[6]=cra;regs[7]=cra>>32;cra=0;}
    else {assert(v==1);auto d=std::uint64_t(regs[1])|(std::uint64_t(regs[2])<<32);
      for(unsigned b=0;b<8;++b) if(regs[3]&(1u<<b)) {auto m=std::uint64_t(255)<<(8*b);cra=(cra&~m)|(d&m);}}
   }
  } posted.clear();val=regs[ix];
 } else posted.emplace_back(ix,val);
 if(calls==fail_at) {errno=EINTR;return failure;} // operation may already have run
 return 0;
}
void reset(){calls=commands=fail_at=0;failure=-1;posted.clear();for(auto& r:regs)r=0;cra=0x123456789abcdef0ull;}
void finish(Sequencer& s){unsigned n=0;while(s.state()==State::Pending){assert(++n<32);s.advance();}}
}
int main(){
 reset();AclPciPort p(91,0x1000,io);Sequencer s(p,0x1000);
 assert(s.begin(1,128,false,0xaabbccddeeff0011ull,0x35));finish(s);
 assert(s.state()==State::Completed && cra==0x1234ccdd9affde11ull && commands==1);
 assert(s.begin(2,128,true));finish(s);assert(s.value()==0x1234ccdd9affde11ull && cra==0 && commands==2);
 for(auto result:{ssize_t(-1),ssize_t(4),ssize_t(1)}) {
  reset();AclPciPort f(91,0x1000,io);fail_at=1;failure=result;
  assert(f.write32(0x1010,1).outcome==Outcome::Unknown);
  assert(f.fence().outcome==Outcome::Unknown && calls==1);
  assert(f.read32(0x1014).outcome==Outcome::Unknown && calls==1);
 }
 reset();AclPciPort invalid(-1,0x1000,io);
 assert(invalid.fence().outcome==Outcome::NotIssued && calls==0);
 AclPciPort good(91,0x1000,io);
 for(auto a:{0xffcull,0x1001ull,0x1020ull,~0ull}) assert(good.read32(a).outcome==Outcome::NotIssued);
 assert(calls==0);
 // Enlarging the window must be explicit; invalid spans issue no syscall.
 for(auto span:{0ull,20ull,25ull,~0ull}) {
  AclPciPort bad(91,0x1000,io,span);
  assert(bad.read32(0x1000).outcome==Outcome::NotIssued);
 }
 AclPciPort overflow(91,~0ull-31,io,40);
 assert(overflow.fence().outcome==Outcome::NotIssued && calls==0);
 AclPciPort wider(91,0x1000,io,40);
 assert(wider.read32(0x1028).outcome==Outcome::NotIssued && calls==0);
 assert(wider.read32(0x1000).outcome==Outcome::Completed && calls==1);
 // Every syscall boundary in the full mailbox operation can execute then fail.
 for(bool read:{false,true}) {
  reset();AclPciPort r(91,0x1000,io);Sequencer reference(r,0x1000);
  assert(reference.begin(1,128,read,42));finish(reference);auto total=calls;
  for(unsigned boundary=1;boundary<=total;++boundary){
   reset();fail_at=boundary;AclPciPort f(91,0x1000,io);Sequencer q(f,0x1000);
   assert(q.begin(1,128,read,42));finish(q);
   assert(q.state()==State::Poisoned && commands<=1);auto before=calls;
   q.advance();assert(calls==before && !q.begin(2,128,read));
  }
 }
 std::cout<<"ACLPCI_MAILBOX_PORT_PASS\n";
}
