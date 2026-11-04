#include "driver_dma_session.hpp"
#include <sys/eventfd.h>
#include "pcie_linux_driver_exports.h"
#include <unistd.h>
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
static int completion_fd;static bool fail_receipt;static unsigned receipt_reads;
static void* read_buffer;static std::size_t read_bytes;
static ssize_t rd(int fd,void* p,std::size_t n){assert(fd==completion_fd);
 if(static_cast<acl_cmd*>(p)->command==ACLPCI_CMD_DMA_RECEIPT){++receipt_reads;if(fail_receipt)return -1;}
 if(static_cast<acl_cmd*>(p)->command==ACLPCI_CMD_DMA_SUBMIT){
  read_buffer=static_cast<acl_cmd*>(p)->user_addr;read_bytes=static_cast<acl_cmd*>(p)->size;
 }
 return receipt_fixture_read(p,n);}
static unsigned write_submissions;static void* write_buffer;static std::size_t write_bytes,write_address;
static ssize_t wr(int fd,void* p,std::size_t n){assert(fd==completion_fd);
 auto* c=static_cast<acl_cmd*>(p);
 if(c->command==ACLPCI_CMD_DMA_SUBMIT){++write_submissions;write_buffer=c->user_addr;write_bytes=c->size;write_address=reinterpret_cast<std::uintptr_t>(c->device_addr);}
 return receipt_fixture_write(p,n);}
struct BytePort:mailbox::Port {
 std::uint32_t fields[5]{},done=0;bool pending=false;
 unsigned commands=0,calls=0;bool fail_command=false;unsigned char memory[16];
 BytePort(){std::memset(memory,0x55,sizeof memory);}
 mailbox::Reply read32(std::uint64_t a)noexcept override{
  ++calls;assert(a==1024||a==1028||a==1056);
  return {mailbox::Outcome::Completed,a==1024?0x42595702u:a==1028?(pending?1u:done?4u:0u):done};
 }
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v)noexcept override{
  ++calls;if(a==1052){assert(v==1&&!pending);pending=true;++commands;if(fail_command)return {mailbox::Outcome::Unknown};}
  else{assert(a>=1032&&a<=1048&&!(a&3));fields[(a-1032)/4]=v;}
  return {mailbox::Outcome::Completed};
 }
 mailbox::Reply fence()noexcept override{return {mailbox::Outcome::Completed};}
 void complete(){
  assert(pending&&fields[4]==done+1&&fields[1]==0);
  auto offset=fields[0]-0x200000;assert(offset+4<=sizeof memory);
  for(unsigned b=0;b<4;++b)if(fields[3]&(1u<<b))memory[offset+b]=fields[2]>>(8*b);
  done=fields[4];pending=false;
 }
};
// Only hardware and kernel primitives are simulated by the retained C fixture.
// This factory is test-only; it supplies no production discovery or qualification.
struct DriverFixture : Transport {
 DriverDmaSession session{completion_fd,rd,wr};Request request{};
 bool qualified_and_owned() const noexcept override{return true;}
 int info(aocl_mmd_info_t id,std::size_t n,void* out,std::size_t* size)override{
  if(id!=AOCL_MMD_MEMORY_INTERFACE)return -1;
  if(size)*size=sizeof(int);
  if(!out||n<sizeof(int))return -1;
  int value=7;std::memcpy(out,&value,sizeof value);return 0;
 }
 int blocking(const Request&)noexcept override{return -1;}
 Submission submit(const Request& r,Completion c)override{
  if(r.interface_id!=7)return Submission::NotAccepted;
  request=r;return session.submit(r,std::move(c));
 }
 int yield()override{return 0;} // Events explicitly delivered below; no polling.
 int close()override{return session.pending()?-1:0;}
 int interrupt_handler(aocl_mmd_interrupt_handler_fn,void*)override{return -1;}
 void event(){
  // Synthetic kernel notification; the waiter itself uses real native epoll.
  std::uint64_t one=1;assert(::write(completion_fd,&one,sizeof one)==sizeof one);
  auto result=session.wait_one();
  assert(result==DriverDmaSession::Result::Retained||result==DriverDmaSession::Result::Delivered);
  assert(::read(completion_fd,&one,sizeof one)==sizeof one);
 }
 void interrupted(){
  assert(session.interrupt());
  assert(session.wait_one()==DriverDmaSession::Result::Interrupted&&session.pending());
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
 completion_fd=eventfd(0,EFD_NONBLOCK|EFD_CLOEXEC);assert(completion_fd>=0);
 receipt_fixture_begin();auto factory=std::make_shared<Factory>();assert(install_backend(factory));
 auto d=factory->device;Status status;status.handle=aocl_mmd_open("driver-fixture");assert(status.handle>=0);
 assert(!aocl_mmd_set_status_handler(status.handle,completed,&status));
 alignas(16) unsigned char bytes[4]={1,2,3,4};
 assert(!aocl_mmd_write(status.handle,&status,4,bytes,7,0x200000));
 bytes[0]=99;assert(static_cast<unsigned char*>(d->request.staging)[0]==1);
 receipt_fixture_irq_without_status();d->event();assert(flush_ready(status.handle)&&!status.calls);
 assert(aocl_mmd_close(status.handle)<0);d->interrupted();
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
 assert(!aocl_mmd_copy(status.handle,&status,4,7,0x200000,0x200004));
 assert(aocl_mmd_close(status.handle)<0);
 receipt_fixture_complete();d->event();assert(flush_ready(status.handle));
 assert(status.calls==3&&aocl_mmd_close(status.handle)<0);
 receipt_fixture_complete();d->event();assert(flush_ready(status.handle));
 assert(status.calls==4&&!status.result);
 std::memset(bytes,0x55,4);
 assert(!aocl_mmd_read(status.handle,&status,3,bytes,7,0x200001));
 assert(read_bytes==4);
 for(unsigned i=0;i<4;++i)static_cast<unsigned char*>(read_buffer)[i]=i+1;
 for(auto byte:bytes)assert(byte==0x55);
 receipt_fixture_complete();d->event();assert(flush_ready(status.handle));
 assert(status.calls==5&&!status.result&&bytes[0]==2&&bytes[1]==3&&bytes[2]==4&&bytes[3]==0x55);
 assert(!aocl_mmd_close(status.handle));assert(install_backend(nullptr));receipt_fixture_finish();
 d.reset();factory.reset();
 // Actual MMD staging/callback lifecycle across masked head, DMA, masked tail.
 receipt_fixture_begin();factory=std::make_shared<Factory>();d=factory->device;
 BytePort byte_port;assert(d->session.configure_byte_writes(byte_port,1024,0x80000000,1));
 assert(install_backend(factory));status={};status.handle=aocl_mmd_open("driver-fixture");assert(status.handle>=0);
 assert(!aocl_mmd_set_status_handler(status.handle,completed,&status));
 unsigned char payload[8]={1,2,3,4,5,6,7,8};
 for(unsigned round=0;round<2;++round){
  const auto before=write_submissions;
  assert(!aocl_mmd_write(status.handle,&status,8,payload,7,0x200001));
  assert(aocl_mmd_close(status.handle)<0);
  while(write_submissions==before){
   assert(d->session.wait_one()==DriverDmaSession::Result::Retained);
   if(byte_port.pending)byte_port.complete();
   assert(flush_ready(status.handle)&&status.calls==int(round));
  }
  assert(write_address==0x200004&&write_bytes==4);
  std::memcpy(byte_port.memory+4,write_buffer,4);
  receipt_fixture_complete();d->event();
  while(d->session.pending()){
   auto r=d->session.wait_one();
   assert(r==DriverDmaSession::Result::Retained||r==DriverDmaSession::Result::Delivered);
   if(byte_port.pending)byte_port.complete();
  }
  assert(flush_ready(status.handle)&&status.calls==int(round+1)&&!status.result);
  assert(byte_port.commands==2*(round+1)&&!std::memcmp(byte_port.memory+1,payload,8));
  assert(byte_port.memory[0]==0x55&&byte_port.memory[9]==0x55);
 }
 assert(!aocl_mmd_close(status.handle));assert(install_backend(nullptr));receipt_fixture_finish();d.reset();factory.reset();

 // Uncertain edge submission retains staging and never reaches bulk or callback.
 {
  BytePort unknown;unknown.fail_command=true;int callbacks=0;
  DriverDmaSession session(completion_fd,rd,wr);
  assert(session.configure_byte_writes(unknown,1024,0x80000000,1));
  Request request{Kind::Write,7,8,0,0x200001,payload,{9,1}};
  auto submissions=write_submissions;
  assert(session.submit(request,[&](dma::Ticket,int,dma::DrainEvidence){++callbacks;})==Submission::Accepted);
  while(!session.attention())session.wait_one();
  auto calls=unknown.calls;
  assert(session.pending()&&!callbacks&&unknown.commands==1&&write_submissions==submissions);
  assert(session.wait_one()==DriverDmaSession::Result::Attention&&unknown.calls==calls);
  assert(!session.resume_events());
  // Test fixture only: no real hardware references exist at test destruction.
 }
 // Receipt failure after an actual driver retirement: keep ownership, stop
 // automatic event rearming, then resume once after fixing the reader.
 receipt_fixture_begin();
 {
  DriverDmaSession session(completion_fd,rd,wr);int callbacks=0;
  Request request{Kind::Write,7,4,0,0x200000,bytes,{8,1}};
  assert(session.submit(request,[&](dma::Ticket,int result,dma::DrainEvidence){assert(!result);++callbacks;})==Submission::Accepted);
  receipt_fixture_complete();fail_receipt=true;
  std::uint64_t one=1;assert(::write(completion_fd,&one,sizeof one)==sizeof one);
  assert(session.wait_one()==DriverDmaSession::Result::Attention&&session.pending());
  auto reads=receipt_reads;
  assert(session.wait_one()==DriverDmaSession::Result::Attention&&receipt_reads==reads&&!callbacks);
  fail_receipt=false;assert(session.resume_events());
  assert(session.wait_one()==DriverDmaSession::Result::Delivered&&!session.pending()&&callbacks==1);
  assert(::read(completion_fd,&one,sizeof one)==sizeof one);
 }
 receipt_fixture_finish();::close(completion_fd);
 std::cout<<"MMD_EVENT_SESSION_PASS staged_write drained_read cancelled_read early_irq close_retention ordered_copy byte_write_rounds=2 masked_uncertainty\n";
}
