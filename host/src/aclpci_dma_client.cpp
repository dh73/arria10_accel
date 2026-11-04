#include "aclpci_dma_client.hpp"
#include "pcie_linux_driver_exports.h"
#include <limits>
#include <unistd.h>
namespace asus::a10 {
static ssize_t native_write(int fd,void* p,std::size_t n){return ::write(fd,p,n);}
AclPciDmaClient::AclPciDmaClient(int fd,DmaReceiptRead r,DmaReceiptRead w) noexcept
 :fd_(fd),reader_(r ? r : ::read),writer_(w?w:native_write),state_(fd>=0?State::Idle:State::Invalid){}
AclPciDmaClient::State AclPciDmaClient::submit(void* buffer,std::size_t bytes,
 std::uint64_t address,bool reading) noexcept {
 if(state_!=State::Idle)return state_;
 if(!buffer || !bytes || (bytes&3) || (address&3) ||
    (reinterpret_cast<std::uintptr_t>(buffer)&3) ||
    bytes>std::size_t(std::numeric_limits<ssize_t>::max()) ||
    address>std::numeric_limits<std::uintptr_t>::max() ||
    bytes>std::numeric_limits<std::uint64_t>::max()-address)
   return state_=State::Invalid;
 // Refuse older signal-delivering drivers before any DMA submission.
 // This checks software ABI only; image qualification remains separate.
 std::uint32_t capabilities[ACLPCI_DRIVER_CAPABILITIES_WORDS]={ACLPCI_DRIVER_CAPABILITIES_VERSION,0,0,0};
 acl_cmd query{};query.bar_id=ACLPCI_CMD_BAR;query.command=ACLPCI_CMD_DRIVER_CAPABILITIES;
 query.user_addr=capabilities;query.size=sizeof capabilities;
 try {if(reader_(fd_,&query,sizeof query)!=0)return state_=State::Invalid;}
 catch(...) {return state_=State::Invalid;}
 constexpr auto required=ACLPCI_DRIVER_CAP_EVENT_ONLY_DMA|ACLPCI_DRIVER_CAP_EXACT_RECEIPT;
 if(capabilities[0]!=ACLPCI_DRIVER_CAPABILITIES_VERSION ||
    (capabilities[1]&required)!=required || capabilities[2]!=4 ||
    capabilities[3]!=ACLPCI_DMA_RECEIPT_VERSION)return state_=State::Invalid;
 const auto baseline=read_dma_receipt(fd_,0,reader_);
 if((baseline.state!=DmaReceiptState::None && baseline.state!=DmaReceiptState::Drained) ||
    baseline.submitted==std::numeric_limits<std::uint64_t>::max())return state_=State::Unknown;
 generation_=baseline.submitted+1;
 acl_cmd cmd{};cmd.bar_id=ACLPCI_CMD_BAR;cmd.command=ACLPCI_CMD_DMA_SUBMIT;
 cmd.device_addr=reinterpret_cast<void*>(std::uintptr_t(address));
 cmd.user_addr=buffer;cmd.size=bytes;
 state_=State::Unknown; // Reserve before syscall; no retry even on EINTR.
 try {if((reading?reader_:writer_)(fd_,&cmd,sizeof(cmd))==0)state_=State::Pending;}
 catch(...) {}
 return state_;
}
AclPciDmaClient::State AclPciDmaClient::advance() noexcept {
 if(!generation_ || (state_!=State::Pending && state_!=State::Unknown))return state_;
 const auto receipt=read_dma_receipt(fd_,generation_,reader_);
 if(receipt.releases_buffers(generation_)){result_=receipt.result;state_=State::Drained;}
 else if(receipt.state==DmaReceiptState::Pending)state_=State::Pending;
 else state_=State::Unknown;
 return state_;
}
}
