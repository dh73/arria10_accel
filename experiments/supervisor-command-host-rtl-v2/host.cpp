#include "supervisor_command.hpp"
#include "aclpci_mailbox_port.hpp"
#include "pcie_linux_driver_exports.h"
#include <cerrno>
#include <cstdio>
#include <stdexcept>
using namespace asus::a10;
extern "C" int control_reset(int);
extern "C" int control_put(unsigned long long,unsigned int);
extern "C" int control_get(unsigned long long,unsigned int*);
extern "C" int control_observe(int*,int*);
namespace {
constexpr std::uint64_t base=0x100000000ull;
unsigned calls=0,fail_at=0;
ssize_t io(int fd,void* ptr,std::size_t n,bool rd)noexcept{
 ++calls;auto& c=*static_cast<acl_cmd*>(ptr);auto a=reinterpret_cast<std::uintptr_t>(c.device_addr);
 if(fd!=91||n!=4||c.size!=4||c.bar_id!=2||c.command!=ACLPCI_CMD_DEFAULT||a<base||a>=base+32||(a&3))return -1;
 auto& value=*static_cast<std::uint32_t*>(c.user_addr);
 if(rd)control_get(a,&value);else control_put(a,value);
 if(calls==fail_at){errno=EINTR;return -1;}return 0;
}
void need(bool b,const char*why){if(!b)throw std::runtime_error(why);}
void finish(control::Request& r){while(r.state()==control::State::Pending)r.advance();}
}
extern "C" int run_control_host(int* result){*result=1;try{
 for(unsigned why:{0u,5u}){
  control_reset(why);calls=fail_at=0;mailbox::AclPciPort p(91,base,io);
  control::Request r(p,base,0x100000002ull,control::Command::Start);finish(r);
  need(r.state()==(why?control::State::Rejected:control::State::Accepted)&&r.reason()==why,"RTL command result mismatch");
  int offers,commits;control_observe(&offers,&commits);need(offers==1&&commits==1,"duplicate or missing command");
 }
 for(unsigned boundary=1;boundary<=12;boundary++){
  control_reset(0);calls=0;fail_at=boundary;mailbox::AclPciPort p(91,base,io);
  control::Request r(p,base,2,control::Command::Quiesce);finish(r);
  need(r.state()==control::State::Poisoned&&calls==boundary,"uncertain boundary did not poison");
  r.advance();p.read32(base+16);p.write32(base+12,0xa10c0001);need(calls==boundary,"uncertain command replay");
  int offers,commits;control_observe(&offers,&commits);need(offers<=1&&commits==int(boundary>=8),"commit count");
 }
 control_reset(0);calls=fail_at=0;mailbox::AclPciPort p(91,base,io);
 control::Request first(p,base,9,control::Command::Start);finish(first);auto before=calls;
 control::Request stale(p,base,9,control::Command::Resume);finish(stale);
 need(stale.state()==control::State::Poisoned&&calls==before+3,"stale ID submitted");
 int offers,commits;control_observe(&offers,&commits);need(offers==1&&commits==1,"stale ID executed");
 std::puts("CPP_SUPERVISOR_RTL_PASS uncertain_boundaries=12 high_id rejected stale_id");*result=0;
}catch(const std::exception&e){std::fprintf(stderr,"CPP_SUPERVISOR_RTL_FAILURE %s\n",e.what());}return 0;}
