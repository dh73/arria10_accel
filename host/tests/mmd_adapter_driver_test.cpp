#include "driver_dma_operation.hpp"
#include <cassert>
#include <cstring>
#include <cerrno>
#include <iostream>
extern "C" {
void receipt_fixture_begin();long receipt_fixture_read(void*,unsigned long);
long receipt_fixture_write(void*,unsigned long);void receipt_fixture_irq_without_status();
void receipt_fixture_stop();void receipt_fixture_complete();void receipt_fixture_finish();
}
using namespace asus::a10;using namespace asus::a10::mmd;
static ssize_t rd(int fd,void* p,std::size_t n){assert(fd==91);return receipt_fixture_read(p,n);}
static ssize_t wr(int fd,void* p,std::size_t n){assert(fd==91);return receipt_fixture_write(p,n);}
// Only hardware and kernel primitives are simulated by the retained C fixture.
// This factory is test-only; it supplies no production discovery or qualification.
struct DriverFixture : Transport {
 std::shared_ptr<DriverDmaOperation> operation;Request request{};
 bool qualified_and_owned() const noexcept override{return true;}
 int info(aocl_mmd_info_t id,std::size_t n,void* out,std::size_t* size)override{
  if(id!=AOCL_MMD_MEMORY_INTERFACE)return -1;
  if(size)*size=sizeof(int);
  if(!out||n<sizeof(int))return -1;
  int value=7;std::memcpy(out,&value,sizeof value);return 0;
 }
 int blocking(const Request&)noexcept override{return -1;}
 Submission submit(const Request& r,Completion c)override{
  if(operation || r.interface_id!=7)return Submission::NotAccepted;
  request=r;operation=std::make_shared<DriverDmaOperation>(91,r,std::move(c),rd,wr);
  auto result=operation->submit();if(result==Submission::NotAccepted)operation.reset();return result;
 }
 int yield()override{return 0;} // Events explicitly delivered below; no polling.
 int close()override{return operation?-1:0;}
 int interrupt_handler(aocl_mmd_interrupt_handler_fn,void*)override{return -1;}
 void event(){
  auto retained=operation;assert(retained);
  auto result=retained->service();
  if(result==DriverDmaOperation::Service::Delivered)operation.reset();
 }
};
struct Factory : Backend {
 std::shared_ptr<DriverFixture> device=std::make_shared<DriverFixture>();
 std::vector<std::string> discover()override{return {"driver-fixture"};}
 std::shared_ptr<Transport> open(const std::string& n)override{return n=="driver-fixture"?device:nullptr;}
};
struct Status{int calls=0,result=99,handle=-1;};
static void completed(int h,void* p,aocl_mmd_op_t token,int result){
 auto& s=*static_cast<Status*>(p);assert(h==s.handle&&token==p);++s.calls;s.result=result;
}
int main(){
 receipt_fixture_begin();auto factory=std::make_shared<Factory>();assert(install_backend(factory));
 auto d=factory->device;Status status;status.handle=aocl_mmd_open("driver-fixture");assert(status.handle>=0);
 assert(!aocl_mmd_set_status_handler(status.handle,completed,&status));
 alignas(16) unsigned char bytes[4]={1,2,3,4};
 assert(!aocl_mmd_write(status.handle,&status,4,bytes,7,0x200000));
 bytes[0]=99;assert(static_cast<unsigned char*>(d->request.staging)[0]==1);
 receipt_fixture_irq_without_status();d->event();assert(flush_ready(status.handle)&&!status.calls);
 assert(aocl_mmd_close(status.handle)<0);
 receipt_fixture_complete();d->event();assert(flush_ready(status.handle));assert(status.calls==1&&!status.result);
 for(int cancelled=0;cancelled<2;++cancelled){
  std::memset(bytes,0x55,4);
  assert(!aocl_mmd_read(status.handle,&status,4,bytes,7,0x200000));
  // Behavioral device payload written to the adapter-owned pinned destination.
  std::memset(d->request.staging,0xa5,4);
  if(cancelled){receipt_fixture_stop();d->event();assert(flush_ready(status.handle));assert(status.calls==2);}
  for(auto byte:bytes)assert(byte==0x55);
  receipt_fixture_complete();d->event();assert(flush_ready(status.handle));
  assert(status.calls==2+cancelled&&status.result==(cancelled?-ECANCELED:0));
  for(auto byte:bytes)assert(byte==(cancelled?0x55:0xa5));
 }
 assert(!aocl_mmd_close(status.handle));assert(install_backend(nullptr));receipt_fixture_finish();
 std::cout<<"MMD_ADAPTER_DRIVER_PASS staged_write drained_read cancelled_read early_irq close_retention\n";
}
