#include "kernel_context_bridge.hpp"
#include "aclpci_mailbox_port.hpp"
#include "pcie_linux_driver_exports.h"
#include <cerrno>
#include <stdexcept>
#include <cstdio>
using namespace asus::a10;
extern "C" int control_reset();
extern "C" int control_get(unsigned long long,unsigned*);
extern "C" int control_put(unsigned long long,unsigned);
namespace {
constexpr std::uint64_t base=0x100000300ull;
unsigned calls=0,fail=0,commits=0;
ssize_t io(int fd,void* raw,std::size_t n,bool reading)noexcept{
 ++calls;auto& c=*static_cast<acl_cmd*>(raw);auto a=reinterpret_cast<std::uintptr_t>(c.device_addr);
 if(fd!=91||n!=4||c.size!=4||c.bar_id!=2||c.command!=ACLPCI_CMD_DEFAULT||a<base||a>=base+32||(a&3))return -1;
 auto& v=*static_cast<std::uint32_t*>(c.user_addr);
 if(reading)control_get(a,&v);else{control_put(a,v);if(a==base)++commits;}
 // Model an uncertain syscall AFTER the real RTL transaction, including commit.
 if(calls==fail){errno=EINTR;return -1;}return 0;
}
void need(bool b,const char*msg){if(!b)throw std::runtime_error(msg);}
void finish(KernelProvision& c){while(c.state()==KernelState::Pending)c.advance();}
}
extern "C" int run_provision_host(int* result){*result=1;try{
 control_reset();calls=fail=commits=0;mailbox::AclPciPort p(91,base,io,32);
 KernelProvision first(p,base,0x200000001,{0x400000003,0x600000005});finish(first);
 need(first.state()==KernelState::Complete&&calls==19&&commits==1,"provisioning/readback failed");
 KernelProvision second(p,base,7,{8,9});finish(second);
 need(second.state()==KernelState::Poisoned&&commits==1,"replaced existing owner");
 // Fault after binding cannot replace identity.
 control_put(base+8,99);unsigned v;control_get(base+4,&v);need(v==2,"replacement not faulted");
 control_get(base+8,&v);need(v==1,"immutable epoch changed");
 for(unsigned n=1;n<=19;++n){
  control_reset();calls=commits=0;fail=n;mailbox::AclPciPort port(91,base,io,32);
  KernelProvision request(port,base,0x200000001,{0x400000003,0x600000005});finish(request);
  need(request.state()==KernelState::Poisoned&&calls==n,"uncertain I/O accepted");
  request.advance();need(calls==n&&commits<=1,"provision replayed");
 }
 std::puts("CONTEXT_PROVISION_KERNEL_RTL_PASS boundaries=19 immutable_identity no_replay");*result=0;
}catch(const std::exception& e){std::fprintf(stderr,"CONTEXT_PROVISION_CXX_RTL_FAIL %s\n",e.what());}return 0;}
