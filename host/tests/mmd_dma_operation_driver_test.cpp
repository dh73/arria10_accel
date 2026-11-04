#include "driver_dma_operation.hpp"
#include "pcie_linux_driver_exports.h"
#include <cassert>
#include <cerrno>
#include <iostream>
extern "C" {
void receipt_fixture_begin();long receipt_fixture_read(void*,unsigned long);
long receipt_fixture_write(void*,unsigned long);void receipt_fixture_irq_without_status();
void receipt_fixture_stop();void receipt_fixture_complete();void receipt_fixture_finish();
}
using namespace asus::a10;using namespace asus::a10::mmd;
static int submissions;static bool obscure;
static ssize_t io(int fd,void* p,std::size_t n,bool reading){
 assert(fd==91);bool submit=static_cast<acl_cmd*>(p)->command==ACLPCI_CMD_DMA_SUBMIT;
 if(submit)++submissions;
 auto result=reading?receipt_fixture_read(p,n):receipt_fixture_write(p,n);
 return submit&&obscure?-1:result;
}
static ssize_t rd(int f,void* p,std::size_t n){return io(f,p,n,true);}
static ssize_t wr(int f,void* p,std::size_t n){return io(f,p,n,false);}
int main(){
 receipt_fixture_begin();
 for(unsigned i=0;i<3;++i){
  obscure=i==2;int callbacks=0;dma::Ticket ticket{7,i+1};
  Request request{Kind::Read,0,4,0x200000,0,reinterpret_cast<void*>(0x100000),ticket};
  DriverDmaOperation op(91,request,[&](dma::Ticket t,int result,dma::DrainEvidence drain){
   assert(t==ticket && result==(i==1?-ECANCELED:0));
   assert(drain==dma::DrainEvidence::PerOperation);++callbacks;
  },rd,wr);
  auto expected=obscure?Submission::Indeterminate:Submission::Accepted;
  assert(op.submit()==expected && op.submit()==expected && submissions==int(i+1));
  receipt_fixture_irq_without_status();assert(op.service()==DriverDmaOperation::Service::Retained);
  if(i==1){receipt_fixture_stop();assert(op.service()==DriverDmaOperation::Service::Retained);}
  assert(!callbacks);receipt_fixture_complete();
  assert(op.service()==DriverDmaOperation::Service::Delivered && callbacks==1);
  assert(op.service()==DriverDmaOperation::Service::AlreadyDelivered && callbacks==1);
 }
 receipt_fixture_finish();
 std::cout<<"MMD_DMA_DRIVER_PASS success cancelled uncertain no_replay exact_ticket drain_required\n";
}
