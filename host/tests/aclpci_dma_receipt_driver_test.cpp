#include "aclpci_dma_receipt.hpp"
#include <cassert>
#include <cerrno>
#include <iostream>
extern "C" {
void receipt_fixture_begin();
long receipt_fixture_read(void*,unsigned long);
void receipt_fixture_submit();
void receipt_fixture_irq_without_status();
void receipt_fixture_stop();
void receipt_fixture_complete();
void receipt_fixture_finish();
}
using namespace asus::a10;
static ssize_t read_driver(int fd,void* p,std::size_t bytes) {
 assert(fd==91);return receipt_fixture_read(p,bytes);
}
int main(){
 receipt_fixture_begin();
 auto empty=read_dma_receipt(91,0,read_driver);
 assert(empty.state==DmaReceiptState::None && !empty.releases_buffers(0));
 for(std::uint64_t generation=1;generation<=3;++generation){
  receipt_fixture_submit();
  auto pending=read_dma_receipt(91,generation,read_driver);
  assert(pending.state==DmaReceiptState::Pending && !pending.releases_buffers(generation));
  receipt_fixture_irq_without_status();
  assert(!read_dma_receipt(91,generation,read_driver).releases_buffers(generation));
  if(generation==2){
   receipt_fixture_stop();
   assert(!read_dma_receipt(91,generation,read_driver).releases_buffers(generation));
  }
  receipt_fixture_complete();
  auto done=read_dma_receipt(91,generation,read_driver);
  assert(done.releases_buffers(generation));
  assert(done.result==(generation==2?-ECANCELED:0));
  assert(!done.releases_buffers(generation+1));
  if(generation>1)assert(read_dma_receipt(91,generation-1,read_driver).state==DmaReceiptState::Unknown);
 }
 receipt_fixture_finish();
 std::cout<<"DMA_RECEIPT_CLIENT_DRIVER_PASS generations=3 success cancel stale_irq stale_generation\n";
}
