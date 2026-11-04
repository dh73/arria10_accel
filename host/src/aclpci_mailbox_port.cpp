#include "aclpci_mailbox_port.hpp"
#include "pcie_linux_driver_exports.h"
#include <limits>
#include <unistd.h>
namespace asus::a10::mailbox {
AclPciPort::AclPciPort(int fd, std::uint64_t base, Call call) noexcept
 : fd_(fd), base_(base), call_(call), valid_(fd>=0 && call && !(base&3) &&
 base<=std::numeric_limits<std::uintptr_t>::max()-31) {}
ssize_t AclPciPort::native(int fd, void* command, std::size_t n, bool reading) noexcept {
 return reading ? ::read(fd,command,n) : ::write(fd,command,n);
}
Reply AclPciPort::access(std::uint64_t address, std::uint32_t value, bool reading) noexcept {
 if(poisoned_) return {Outcome::Unknown};
 if(!valid_ || address<base_ || address-base_>=32 || (address&3)) return {Outcome::NotIssued};
 acl_cmd cmd{}; cmd.bar_id=2; cmd.command=ACLPCI_CMD_DEFAULT;
 cmd.device_addr=reinterpret_cast<void*>(static_cast<std::uintptr_t>(address));
 cmd.user_addr=&value; cmd.size=sizeof(value); cmd.is_diff_endian=0;
 // A negative or unexpected positive return cannot prove a command did not run.
 // In particular EFAULT can follow the read-clear device transaction.
 if(call_(fd_, &cmd, sizeof(value), reading)!=0) {
   poisoned_=true; return {Outcome::Unknown};
 }
 return {Outcome::Completed, reading?value:0};
}
Reply AclPciPort::write32(std::uint64_t a,std::uint32_t v) noexcept {return access(a,v,false);}
Reply AclPciPort::read32(std::uint64_t a) noexcept {return access(a,0,true);}
Reply AclPciPort::fence() noexcept {
 // Non-destructive mailbox STATUS read: ordered same-function PCIe completion
 // flushes preceding posted BAR writes. CPU fences alone are insufficient.
 if(!valid_) return {Outcome::NotIssued};
 return access(base_+20,0,true);
}
}
