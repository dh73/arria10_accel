#include "ddr_byte_write.hpp"
#include "aclpci_mailbox_port.hpp"
#include "pcie_linux_driver_exports.h"
extern "C" {int byte_get(unsigned long long,unsigned*);int byte_put(unsigned long long,unsigned);}
using namespace asus::a10;
static ssize_t syscall_fixture(int fd,void* raw,std::size_t size,bool reading)noexcept {
 if(fd!=91 || size!=4)return -1;
 auto* cmd=static_cast<acl_cmd*>(raw);
 if(cmd->bar_id!=2 || cmd->command!=ACLPCI_CMD_DEFAULT || cmd->size!=4 ||
    cmd->is_diff_endian || !cmd->user_addr)return -1;
 auto a=reinterpret_cast<std::uintptr_t>(cmd->device_addr);
 if(a<1024 || a>1056 || (a&3))return -1;
 auto* value=static_cast<unsigned*>(cmd->user_addr);
 return reading?byte_get(a,value):byte_put(a,*value);
}
extern "C" int byte_host(int* result){
 mailbox::AclPciPort port(91,1024,syscall_fixture,36);unsigned sequence=0;*result=1;
 for(unsigned slot=0;slot<16;++slot)for(unsigned mask=1;mask<16;++mask){
  ++sequence;memory::ByteWrite op(port,1024,0x80000000,0x1000+4*slot,0xa1b2c3d4^sequence,mask,sequence);
  while(op.state()==memory::WriteState::Progress||op.state()==memory::WriteState::AwaitingCompletion)op.advance();
  if(op.state()!=memory::WriteState::Complete)return 0;
 }
 *result=0;return 0;
}
