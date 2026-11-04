#include "aclpci_dma_client.hpp"
#include "pcie_linux_driver_exports.h"
#include <cassert>
#include <cerrno>
#include <iostream>
extern "C" {
void receipt_fixture_begin();long receipt_fixture_read(void*,unsigned long);
long receipt_fixture_write(void*,unsigned long);void receipt_fixture_irq_without_status();
void receipt_fixture_stop();void receipt_fixture_complete();void receipt_fixture_finish();
}
static unsigned submissions;static bool obscure;
static ssize_t io(int fd,void* p,std::size_t n,bool reading){
 assert(fd==91);auto* cmd=static_cast<acl_cmd*>(p);
 bool submit=cmd->command==ACLPCI_CMD_DMA_SUBMIT;
 if(submit)++submissions;
 auto result=reading?receipt_fixture_read(p,n):receipt_fixture_write(p,n);
 return submit&&obscure?-1:result;
}
static ssize_t rd(int f,void* p,std::size_t n){return io(f,p,n,true);}
static ssize_t wr(int f,void* p,std::size_t n){return io(f,p,n,false);}
int main(){
 using C=asus::a10::AclPciDmaClient;
 receipt_fixture_begin();
 for(unsigned i=0;i<3;++i){
  obscure=i==2;C client(91,rd,wr);
  auto initial=client.submit(reinterpret_cast<void*>(0x100000),4,0x200000,i!=1);
  assert(initial==(obscure?C::State::Unknown:C::State::Pending));
  assert(client.generation()==i+1);
  client.submit(reinterpret_cast<void*>(0x100000),4,0x200000,true);
  assert(submissions==i+1); // No repeated submission after uncertain acceptance.
  receipt_fixture_irq_without_status();assert(client.advance()==C::State::Pending);
  if(i==1){receipt_fixture_stop();assert(client.advance()==C::State::Pending);}
  receipt_fixture_complete();assert(client.advance()==C::State::Drained);
  assert(client.result()==(i==1?-ECANCELED:0));
  assert(client.advance()==C::State::Drained);
 }
 receipt_fixture_finish();
 std::cout<<"DMA_CLIENT_DRIVER_PASS success cancellation uncertain_acceptance no_replay\n";
}
