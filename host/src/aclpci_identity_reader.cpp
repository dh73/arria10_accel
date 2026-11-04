#include "aclpci_identity_reader.hpp"
#include "pcie_linux_driver_exports.h"
#include <limits>
#include <unistd.h>
namespace asus::a10::image {
AclPciReader::AclPciReader(int fd,std::uint64_t base,std::uint64_t channel,Call call) noexcept
 : fd_(fd),base_(base),channel_(channel),call_(call),closed_(fd<0 || !channel || !call ||
 (base&3) || base>std::numeric_limits<std::uintptr_t>::max()-(block_bytes-1)) {}
ssize_t AclPciReader::native(int fd,void* cmd,std::size_t n,bool reading) noexcept {
 return reading ? ::read(fd,cmd,n) : -1;
}
Reply AclPciReader::read32(Request r) noexcept {
 Reply reply{r,false,0};
 if(closed_)return reply;
 if(r.channel!=channel_ || !r.serial || r.serial<=last_ ||
    (r.offset&3) || r.offset>block_bytes-4) {closed_=true;return reply;}
 last_=r.serial;
 std::uint32_t value=0;acl_cmd command{};
 command.bar_id=2;command.command=ACLPCI_CMD_DEFAULT;
 command.device_addr=reinterpret_cast<void*>(static_cast<std::uintptr_t>(base_+r.offset));
 command.user_addr=&value;command.size=sizeof(value);command.is_diff_endian=0;
 if(call_(fd_,&command,sizeof(value),true)!=0){closed_=true;return reply;}
 reply.completed=true;reply.value=value;return reply;
}
}
