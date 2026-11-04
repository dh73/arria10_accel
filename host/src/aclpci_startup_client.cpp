#include "aclpci_startup_client.hpp"
#include "pcie_linux_driver_exports.h"
#include <unistd.h>
namespace asus::a10 {
AclPciStartupClient::AclPciStartupClient(int fd, Call call) noexcept
 : fd_(fd), call_(call), state_(fd>=0 && call ? State::Idle : State::Invalid) {}
ssize_t AclPciStartupClient::native(int fd,void* p,std::size_t n,bool reading) noexcept {
 return reading ? ::read(fd,p,n) : ::write(fd,p,n);
}
ssize_t AclPciStartupClient::invoke(std::array<std::uint32_t,10>& words,bool reading) noexcept {
 static_assert(sizeof(words)==40);
 acl_cmd command{};
 command.bar_id=ACLPCI_CMD_BAR;command.command=ACLPCI_CMD_STARTUP;
 command.user_addr=words.data();command.size=sizeof(words);
 return call_(fd_,&command,sizeof(command),reading);
}
AclPciStartupClient::State AclPciStartupClient::arm(
 const std::array<std::uint32_t,6>& context,std::uint64_t id) noexcept {
 if(state_!=State::Idle) return state_;
 if(!id) return state_=State::Invalid;
 std::array<std::uint32_t,10> words{};
 words[0]=ACLPCI_STARTUP_UAPI_VERSION;words[1]=ACLPCI_STARTUP_UAPI_ARM;
 for(unsigned i=0;i<6;++i)words[i+2]=context[i];
 words[8]=static_cast<std::uint32_t>(id);words[9]=static_cast<std::uint32_t>(id>>32);
 // Even EINTR is treated conservatively; the wrapper never reissues ARM.
 state_=State::Unknown;
 if(invoke(words,false)==0)state_=State::Pending;
 return state_;
}
AclPciStartupClient::State AclPciStartupClient::advance() noexcept {
 if(state_!=State::Pending)return state_;
 std::array<std::uint32_t,10> words{};
 words[0]=ACLPCI_STARTUP_UAPI_VERSION;words[1]=ACLPCI_STARTUP_UAPI_STEP;
 state_=State::Unknown;
 switch(invoke(words,true)) {
 case 0:state_=State::Pending;break;
 case 1:state_=State::Accepted;break;
 case 2:state_=State::Rejected;break;
 default:break;
 }
 return state_;
}
}
