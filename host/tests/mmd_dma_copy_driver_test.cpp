#include "driver_dma_copy.hpp"
#include "pcie_linux_driver_exports.h"
#include <cassert>
#include <cstring>
#include <iostream>
extern "C" {
void receipt_fixture_begin();long receipt_fixture_read(void*,unsigned long);
long receipt_fixture_write(void*,unsigned long);void receipt_fixture_complete();
void receipt_fixture_stop();void receipt_fixture_finish();
}
using namespace asus::a10;using namespace asus::a10::mmd;
static unsigned reads,writes;static void* staging;static bool obscure;
static ssize_t rd(int,void* p,std::size_t n){
 auto* cmd=static_cast<acl_cmd*>(p);
 if(cmd->command==ACLPCI_CMD_DMA_SUBMIT){++reads;staging=cmd->user_addr;assert(cmd->size==8);}
 return receipt_fixture_read(p,n);
}
static ssize_t wr(int,void* p,std::size_t n){
 auto* cmd=static_cast<acl_cmd*>(p);assert(cmd->command==ACLPCI_CMD_DMA_SUBMIT);
 ++writes;assert(cmd->size==8&&cmd->user_addr==staging);
 for(unsigned i=0;i<8;++i)assert(static_cast<unsigned char*>(staging)[i]==0xa5);
 auto result=receipt_fixture_write(p,n);return obscure?-1:result;
}
int main(){
 receipt_fixture_begin();
 for(unsigned scenario=0;scenario<3;++scenario){
  unsigned previous=writes;int callbacks=0;obscure=scenario==1;
  Request request{Kind::Copy,7,8,0x200000,0x200004,nullptr,{7,scenario+1}};
  DriverDmaCopy copy(91,request,[&](dma::Ticket t,int result,dma::DrainEvidence drain){
   assert(t==request.ticket&&result==(scenario==2?-ECANCELED:0));
   assert(drain==dma::DrainEvidence::PerOperation);++callbacks;
  },rd,wr);
  assert(copy.submit()==Submission::Accepted&&copy.submit()==Submission::Accepted);
  assert(reads==scenario+1&&writes==previous&&!callbacks);
  assert(copy.service()==DriverDmaCopy::Service::Retained&&writes==previous);
  std::memset(staging,0xa5,8); // Behavioral device data, not hardware evidence.
  if(scenario==2)receipt_fixture_stop();
  receipt_fixture_complete();
  auto result=copy.service();
  if(scenario==2){assert(result==DriverDmaCopy::Service::Delivered&&writes==previous);}
  else {
   assert(result==DriverDmaCopy::Service::Retained&&writes==previous+1&&!callbacks);
   assert(copy.service()==DriverDmaCopy::Service::Retained&&writes==previous+1);
   receipt_fixture_complete();assert(copy.service()==DriverDmaCopy::Service::Delivered);
  }
  assert(callbacks==1&&copy.service()==DriverDmaCopy::Service::AlreadyDelivered);
 }
 receipt_fixture_finish();
 std::cout<<"MMD_DMA_COPY_PASS ordered overlap_staging uncertain_write no_replay cancelled_read\n";
}
