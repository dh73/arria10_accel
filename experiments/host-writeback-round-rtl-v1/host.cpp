#include "host_writeback_round.hpp"
#include "aclpci_mailbox_port.hpp"
#include "pcie_linux_driver_exports.h"
#include <cstdio>
#include <cerrno>
#include <stdexcept>
#include <vector>
using namespace asus::a10;
extern "C" int fence_reset();
extern "C" int fence_put(unsigned long long,unsigned int);
extern "C" int fence_get(unsigned long long,unsigned int*);
extern "C" int fence_mutate(int);
extern "C" int fence_observe(int*,int*,int*,int*,int*);
namespace {
constexpr std::uint64_t base=0x100000000ull;
const std::array<std::uint32_t,6> context{1,2,3,4,5,6};
unsigned calls=0,fail_at=0,mutate_at=0;int mutate_word=0;bool bad_abi=false;
std::vector<unsigned> accesses;
ssize_t io(int fd,void* ptr,std::size_t n,bool reading) noexcept{
 ++calls;auto& c=*static_cast<acl_cmd*>(ptr);auto a=reinterpret_cast<std::uintptr_t>(c.device_addr);
 if(fd!=91||n!=4||c.size!=4||c.bar_id!=2||c.command!=ACLPCI_CMD_DEFAULT||c.is_diff_endian!=0||a<base||a>=base+40||(a&3)){bad_abi=true;return -1;}
 if(calls==mutate_at)fence_mutate(mutate_word);
 auto& value=*static_cast<std::uint32_t*>(c.user_addr);
 accesses.push_back(unsigned(a-base)|(reading?0x100u:0));
 if(reading)fence_get(a,&value);else fence_put(a,value);
 if(calls==fail_at){errno=EINTR;return -1;} // Already executed; outcome is uncertain.
 return 0;
}
void need(bool b,const char*why){if(!b)throw std::runtime_error(why);}
void reset(){fence_reset();calls=fail_at=mutate_at=0;bad_abi=false;accesses.clear();}
void finish(writeback::RoundFence& f){while(f.state()==writeback::State::Pending)f.advance();need(!bad_abi,"ACLPCI syscall ABI mismatch");}
void no_replay(writeback::RoundFence& f,mailbox::AclPciPort& p){auto n=calls;for(int i=0;i<3;i++)f.advance();need(n==calls,"terminal Fence replay");(void)p;}
struct Observation{int settled,fault,commits,mask,io;Observation(){fence_observe(&settled,&fault,&commits,&mask,&io);}};
}
extern "C" int run_writeback_host(int* result){*result=1;try{
 reset();mailbox::AclPciPort p(91,base,io,40);writeback::RoundFence f(p,base,context,1);finish(f);
 const std::vector<unsigned> want{0x100,0x104,0x108,0x10c,0x110,0x114,0x118,0x11c,0x120,0x100,4,8,12,16,20,24,28,32,0x114,36,0x100};
 need(f.state()==writeback::State::Settled&&calls==21&&accesses==want,"21-I/O fence sequence mismatch");
 {Observation o;need(o.settled&&!o.fault&&o.commits==1&&o.mask==255&&o.io==21,"happy RTL state");}no_replay(f,p);
 for(unsigned boundary=1;boundary<=21;boundary++){
  reset();fail_at=boundary;mailbox::AclPciPort q(91,base,io,40);writeback::RoundFence x(q,base,context,1);finish(x);
  need(x.state()==writeback::State::Poisoned&&calls==boundary,"uncertain boundary did not poison");no_replay(x,q);
  auto n=calls;q.read32(base);q.write32(base+36,0xa10f0001);need(calls==n,"poisoned ACLPCI replay");
  Observation o;need(!o.fault&&o.commits==int(boundary>=20)&&o.settled==int(boundary>=20)&&o.io==int(boundary),"uncertain operation execution count");
  if(boundary>=11&&boundary<=18)need(o.mask==int((1u<<(boundary-10))-1),"partial staging was lost or completed implicitly");
 }
 for(unsigned word=0;word<6;word++){
  reset();auto stale=context;stale[word]^=0x100;mailbox::AclPciPort q(91,base,io,40);writeback::RoundFence x(q,base,stale,1);finish(x);
  need(x.state()==writeback::State::Poisoned&&calls==word+2,"stale context accepted");Observation o;need(!o.settled&&!o.commits&&!o.mask,"stale context wrote device");no_replay(x,q);
  reset();mutate_at=10;mutate_word=int(word);mailbox::AclPciPort z(91,base,io,40);writeback::RoundFence y(z,base,context,1);finish(y);
  need(y.state()==writeback::State::Poisoned&&calls==10,"mutated context bypassed recheck");Observation changed;need(changed.fault&&!changed.settled&&!changed.commits&&!changed.mask,"context mutation lost RTL fault");no_replay(y,z);
 }
 std::puts("CPP_ACLPCI_ROUND_RTL_PASS happy=1 uncertainty=21 stale=6 mutated=6 physical_ordering=unqualified");*result=0;
}catch(const std::exception&e){std::fprintf(stderr,"WRITEBACK_HOST_RTL_FAILURE %s\n",e.what());}return 0;}
