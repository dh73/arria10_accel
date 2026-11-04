#include "reset_diagnostics.hpp"
#include "aclpci_mailbox_port.hpp"
#include "pcie_linux_driver_exports.h"
#include <limits>
extern "C" {int diag_get(unsigned long long,unsigned*);int diag_flags(unsigned);}
using namespace asus::a10;
static unsigned calls=0,inject=0;
static ssize_t syscall_fixture(int fd,void* raw,std::size_t size,bool reading)noexcept {
 ++calls;
 if(fd!=91||size!=4||!reading)return -1;
 auto* cmd=static_cast<acl_cmd*>(raw);
 if(cmd->bar_id!=2||cmd->command!=ACLPCI_CMD_DEFAULT||cmd->size!=4||cmd->is_diff_endian||!cmd->user_addr)return -1;
 auto a=reinterpret_cast<std::uintptr_t>(cmd->device_addr);
 if(a!=1088&&a!=1092)return -1;
 if(inject==calls)return -1;
 auto* value=static_cast<unsigned*>(cmd->user_addr);int r=diag_get(a,value);
 if(inject==3&&a==1088)*value^=1;
 if(inject==4&&a==1092)*value|=256;
 return r;
}
extern "C" int diagnostic_host(int* result){
 *result=1;mailbox::AclPciPort port(91,1088,syscall_fixture,24);
 for(unsigned flags=0;flags<256;++flags){
  diag_flags(flags);calls=0;auto s=diagnostics::capture(port,1088);
  if(s.code!=diagnostics::Code::Observed||s.flags!=flags||calls!=2)return 0;
  if(s.reports(diagnostics::Snapshot::DmaEpochLost)!=bool(flags&8))return 0;
 }
 for(unsigned fail=1;fail<=4;++fail){
  mailbox::AclPciPort isolated(91,1088,syscall_fixture,24);
  inject=fail;calls=0;auto s=diagnostics::capture(isolated,1088);
  auto expected=fail<=2?diagnostics::Code::Unknown:fail==3?diagnostics::Code::Unsupported:diagnostics::Code::Malformed;
  if(s.code!=expected||s.flags||s.reports(diagnostics::Snapshot::MemoryReady)||calls!=(fail==1||fail==3?1u:2u))return 0;
 }
 inject=0;calls=0;
 mailbox::AclPciPort invalid(-1,1088,syscall_fixture,24);
 if(diagnostics::capture(invalid,1088).code!=diagnostics::Code::NotIssued||calls)return 0;
 if(diagnostics::capture(port,1089).code!=diagnostics::Code::InvalidMapping||calls)return 0;
 if(diagnostics::capture(port,std::numeric_limits<std::uint64_t>::max()-3).code!=diagnostics::Code::InvalidMapping||calls)return 0;
 *result=0;return 0;
}
