#include "driver_byte_write.hpp"
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
static unsigned submissions;static void* buffer;static std::size_t bytes,address;
static ssize_t rd(int,void* p,std::size_t n){return receipt_fixture_read(p,n);}
static ssize_t wr(int,void* p,std::size_t n){
 auto* c=static_cast<acl_cmd*>(p);
 if(c->command==ACLPCI_CMD_DMA_SUBMIT){++submissions;buffer=c->user_addr;bytes=c->size;address=reinterpret_cast<std::uintptr_t>(c->device_addr);}
 return receipt_fixture_write(p,n);
}
struct Port:mailbox::Port {
 std::array<unsigned char,128> memory;std::uint32_t fields[5]{},done=0;
 unsigned commands=0,calls=0;bool pending=false,fail_command=false;
 Port(){memory.fill(0xa5);}
 mailbox::Reply read32(std::uint64_t a)noexcept override{
  ++calls;assert(a==1024||a==1028||a==1056);
  return {mailbox::Outcome::Completed,a==1024?0x42595701u:a==1028?(pending?1u:done?4u:0u):done};
 }
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v)noexcept override{
  ++calls;
  if(a==1052){assert(v==1&&!pending);++commands;pending=true;
   if(fail_command)return {mailbox::Outcome::Unknown};
  }else{assert(a>=1032&&a<=1048&&!(a&3));fields[(a-1032)/4]=v;}
  return {mailbox::Outcome::Completed};
 }
 mailbox::Reply fence()noexcept override{++calls;return {mailbox::Outcome::Completed};}
 void complete(){
  assert(pending&&fields[1]==0&&fields[4]==done+1);
  auto a=fields[0]-0x200000;assert(a+4<=memory.size());
  for(unsigned lane=0;lane<4;++lane)if(fields[3]&(1u<<lane))memory[a+lane]=fields[2]>>(8*lane);
  done=fields[4];pending=false;
 }
};
int main(){
 using S=DriverByteWrite::State;unsigned cases=0;
 for(unsigned head=0;head<4;++head)for(unsigned size=1;size<=33;++size){
  receipt_fixture_begin();submissions=0;Port p;
  alignas(4) unsigned char source[40];for(unsigned i=0;i<40;++i)source[i]=i*19+7;
  Request r{Kind::Write,7,size,0,0x200000+head,source,{1,1}};
  DriverByteWrite op(91,p,1024,0x80000000,r,1,rd,wr);
  auto expected=p.memory;std::memcpy(expected.data()+head,source,size);
  unsigned completed_dma=0;
  while(op.state()!=S::Accepted){
   auto s=op.advance();assert(s!=S::Failed&&s!=S::Rejected&&s!=S::Attention);
   if(s==S::MailboxPending){assert(p.pending);p.complete();}
   if(s==S::DmaPending&&submissions>completed_dma){
    assert(address>=0x200000&&address+bytes<=0x200080);
    std::memcpy(p.memory.data()+address-0x200000,buffer,bytes);
    receipt_fixture_complete();++completed_dma;
   }
  }
  assert(p.memory==expected&&p.commands==op.sequence_count()&&submissions<=1);
  auto calls=p.calls;assert(op.advance()==S::Accepted&&calls==p.calls);
  receipt_fixture_finish();++cases;
 }
 // Cancelled bulk must not submit the tail after a completed head.
 receipt_fixture_begin();submissions=0;Port p;unsigned char source[16]{};
 Request r{Kind::Write,7,8,0,0x200001,source,{2,1}};
 DriverByteWrite cancelled(91,p,1024,0x80000000,r,1,rd,wr);
 while(cancelled.state()!=S::DmaPending){auto s=cancelled.advance();if(s==S::MailboxPending)p.complete();}
 receipt_fixture_stop();receipt_fixture_complete();assert(cancelled.advance()==S::Failed);
 assert(p.commands==1&&submissions==1&&cancelled.dma_result()==-ECANCELED);
 receipt_fixture_finish();
 // Ambiguous mailbox submit retains debt and forbids bulk/tail or replay.
 Port bad;bad.fail_command=true;submissions=0;
 DriverByteWrite unknown(91,bad,1024,0x80000000,r,1,rd,wr);
 while(unknown.state()!=S::Attention)unknown.advance();
 auto calls=bad.calls;unknown.advance();assert(calls==bad.calls&&bad.commands==1&&!submissions);
 DriverByteWrite overflow(91,bad,1024,0x80000000,r,0xffffffffu,rd,wr);
 assert(overflow.state()==S::Rejected&&calls==bad.calls);
 std::cout<<"DRIVER_BYTE_WRITE_PASS cases="<<cases<<" exact_bytes head_bulk_tail cancellation uncertainty sequence_overflow\n";
}
