#include "aclpci_dma_receipt.hpp"
#include "pcie_linux_driver_exports.h"
#include <array>
#include <cassert>
#include <cstring>
#include <stdexcept>
using namespace asus::a10;
static std::array<std::uint32_t,8> response;
static std::uint64_t expected;
static int calls,mode;
static ssize_t read_fixture(int fd,void* ptr,std::size_t bytes) {
 ++calls;assert(fd==7 && bytes==sizeof(acl_cmd));auto& c=*static_cast<acl_cmd*>(ptr);
 assert(c.bar_id==ACLPCI_CMD_BAR && c.command==ACLPCI_CMD_DMA_RECEIPT);
 assert(c.size==32 && !c.device_addr && !c.is_diff_endian);
 auto* w=static_cast<std::uint32_t*>(c.user_addr);
 assert(w[0]==1 && !w[1] && w[2]==std::uint32_t(expected) && w[3]==std::uint32_t(expected>>32));
 for(int i=4;i<8;++i)assert(!w[i]);
 if(mode==1)return -1;
 if(mode==2)return 32;
 if(mode==3)throw std::runtime_error("unknown");
 std::memcpy(w,response.data(),32);return 0;
}
int main(){
 expected=0;response={1,0,0,0,0,0,0,0};assert(read_dma_receipt(7,expected,read_fixture).state==DmaReceiptState::None);
 expected=0x100000002ULL;response={1,1,2,1,1,1,0,0};assert(!read_dma_receipt(7,expected,read_fixture).releases_buffers(expected));
 response={1,2,2,1,2,1,0,0};assert(read_dma_receipt(7,expected,read_fixture).releases_buffers(expected));
 response[6]=std::uint32_t(-125);assert(read_dma_receipt(7,expected,read_fixture).releases_buffers(expected));
 expected=0;assert(!read_dma_receipt(7,expected,read_fixture).releases_buffers(0));
 expected=0x100000003ULL;assert(read_dma_receipt(7,expected,read_fixture).state==DmaReceiptState::Unknown);
 expected=0x100000002ULL;
 for(mode=1;mode<=3;++mode)assert(read_dma_receipt(7,expected,read_fixture).state==DmaReceiptState::Unknown);
 mode=0;response[6]=1;assert(read_dma_receipt(7,expected,read_fixture).state==DmaReceiptState::Unknown);
 response[6]=0;response[7]=1;assert(read_dma_receipt(7,expected,read_fixture).state==DmaReceiptState::Unknown);
 int before=calls;assert(read_dma_receipt(-1,expected,read_fixture).state==DmaReceiptState::Unknown);assert(calls==before);
}
