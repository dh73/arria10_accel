#include "aclpci_identity_snapshot.hpp"
#include "pcie_linux_driver_exports.h"
#include <unistd.h>
namespace asus::a10 {
image::Capture read_identity_snapshot(int fd,IdentitySnapshotRead reader) noexcept {
 image::Capture capture{};capture.code=image::Code::IoFailure;
 if(fd<0)return capture;
 std::array<std::uint32_t,ACLPCI_IDENTITY_UAPI_WORDS> words{};
 words[0]=ACLPCI_IDENTITY_UAPI_VERSION;
 acl_cmd cmd{};cmd.bar_id=ACLPCI_CMD_BAR;cmd.command=ACLPCI_CMD_IDENTITY_SNAPSHOT;
 cmd.user_addr=words.data();cmd.size=sizeof words;
 try {if((reader?reader : ::read)(fd,&cmd,sizeof cmd)!=0)return capture;}
 catch(...) {return capture;}
 if(words[0]!=ACLPCI_IDENTITY_UAPI_VERSION||words[1]){
  capture.code=image::Code::Malformed;return capture;
 }
 capture.raw.before=words[2];capture.raw.after=words[67];
 for(unsigned i=0;i<64;++i)capture.raw.words[i]=words[3+i];
 if(!capture.raw.before)capture.code=image::Code::Invalid;
 else capture.code=capture.raw.before==capture.raw.after&&capture.raw.before==capture.raw.words[6]
     ?image::Code::Consistent:image::Code::Torn;
 return capture;
}
}
