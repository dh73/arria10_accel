#include "aclpci_dma_receipt.hpp"
#include "pcie_linux_driver_exports.h"
#include <cstring>
#include <unistd.h>
namespace asus::a10 {
DmaReceipt read_dma_receipt(int fd, std::uint64_t expected,
                           DmaReceiptRead reader) noexcept {
  if(fd<0) return {};
  std::uint32_t words[ACLPCI_DMA_RECEIPT_WORDS]{};
  words[0]=ACLPCI_DMA_RECEIPT_VERSION;
  words[2]=std::uint32_t(expected);words[3]=std::uint32_t(expected>>32);
  acl_cmd command{};command.bar_id=ACLPCI_CMD_BAR;
  command.command=ACLPCI_CMD_DMA_RECEIPT;command.user_addr=words;
  command.size=sizeof(words);
  if(!reader) reader=::read;
  try { if(reader(fd,&command,sizeof(command))!=0) return {}; }
  catch(...) { return {}; }
  if(words[0]!=ACLPCI_DMA_RECEIPT_VERSION || words[7]) return {};
  DmaReceipt r;
  r.submitted=std::uint64_t(words[2])|(std::uint64_t(words[3])<<32);
  r.completed=std::uint64_t(words[4])|(std::uint64_t(words[5])<<32);
  std::memcpy(&r.result,&words[6],sizeof(r.result));
  if(expected && expected!=r.submitted) return {};
  if(r.completed>r.submitted || r.result>0) return {};
  switch(words[1]) {
    case ACLPCI_DMA_RECEIPT_NONE:
      if(r.submitted || r.completed || r.result) return {};
      r.state=DmaReceiptState::None;break;
    case ACLPCI_DMA_RECEIPT_PENDING:
      if(!r.submitted || r.completed==r.submitted || r.result) return {};
      r.state=DmaReceiptState::Pending;break;
    case ACLPCI_DMA_RECEIPT_DRAINED:
      if(!r.submitted || r.completed!=r.submitted) return {};
      r.state=DmaReceiptState::Drained;break;
    default:return {};
  }
  return r;
}
}
