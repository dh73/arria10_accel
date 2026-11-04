#include "driver_dma_operation.hpp"
#include "pcie_linux_driver_exports.h"
#include <cassert>
#include <cstring>
#include <iostream>
extern "C" {
void receipt_fixture_begin();long receipt_fixture_read(void*,unsigned long);
void receipt_fixture_stop();void receipt_fixture_complete();void receipt_fixture_finish();
}
using namespace asus::a10;using namespace asus::a10::mmd;
static void* dma_buffer;static std::size_t dma_bytes,dma_address;static unsigned submissions;
static ssize_t reader(int,void* p,std::size_t n){
 auto* cmd=static_cast<acl_cmd*>(p);
 if(cmd->command==ACLPCI_CMD_DMA_SUBMIT){
  ++submissions;dma_buffer=cmd->user_addr;dma_bytes=cmd->size;
  dma_address=reinterpret_cast<std::uintptr_t>(cmd->device_addr);
  assert(!(dma_address&3)&&!(dma_bytes&3)&&!(reinterpret_cast<std::uintptr_t>(dma_buffer)&3));
 }
 return receipt_fixture_read(p,n);
}
int main(){
 unsigned cases=0;
 for(unsigned head=0;head<4;++head)for(unsigned length=1;length<=17;++length)for(bool cancel:{false,true}){
  receipt_fixture_begin();submissions=0;int callbacks=0;
  unsigned char destination[32];std::memset(destination,0x55,sizeof destination);
  Request request{Kind::Read,7,length,0x200000+head,0,destination+5,{1,1}};
  DriverDmaOperation op(91,request,[&](dma::Ticket,int result,dma::DrainEvidence evidence){
   assert(result==(cancel?-ECANCELED:0)&&evidence==dma::DrainEvidence::PerOperation);++callbacks;
  },reader,reader);
  assert(op.submit()==Submission::Accepted&&submissions==1);
  assert(dma_address==0x200000&&dma_bytes==((length+head+3)&~3u));
  for(std::size_t i=0;i<dma_bytes;++i)static_cast<unsigned char*>(dma_buffer)[i]=static_cast<unsigned char>(i+1);
  for(auto byte:destination)assert(byte==0x55);
  if(cancel)receipt_fixture_stop();
  receipt_fixture_complete();assert(op.service()==DriverDmaOperation::Service::Delivered&&callbacks==1);
  for(unsigned i=0;i<sizeof destination;++i){
   auto expected=(!cancel&&i>=5&&i<5+length)?head+i-5+1:0x55;
   assert(destination[i]==expected);
  }
  receipt_fixture_finish();++cases;
 }
 // Wrapped aligned envelope must reject before allocation or syscall.
 unsigned char byte;Request invalid{Kind::Read,7,2,std::numeric_limits<std::size_t>::max(),0,&byte,{2,1}};
 DriverDmaOperation op(91,invalid,[](dma::Ticket,int,dma::DrainEvidence){assert(false);},reader,reader);
 auto before=submissions;assert(op.submit()==Submission::NotAccepted&&submissions==before);
 std::cout<<"MMD_BYTE_READ_PASS cases="<<cases<<" exact_slice cancellation bounds no_early_copy\n";
}
