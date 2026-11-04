#include "platform_closed_startup.hpp"
#include <cstdio>
extern "C" {
int startup_get(unsigned long long,unsigned*);
int startup_put(unsigned long long,unsigned);
}
namespace {
using namespace asus::a10;
class Port final:public mailbox::Port {
 unsigned flush_address_,expected_;
 public:
 Port(unsigned address,unsigned expected):flush_address_(address),expected_(expected){}
 mailbox::Reply read32(std::uint64_t address)noexcept override{
  unsigned value=0;int rc=startup_get(address,&value);
  return {rc?mailbox::Outcome::Unknown:mailbox::Outcome::Completed,value};
 }
 mailbox::Reply write32(std::uint64_t address,std::uint32_t value)noexcept override{
  return {startup_put(address,value)?mailbox::Outcome::Unknown:mailbox::Outcome::Completed,0};
 }
 mailbox::Reply fence()noexcept override{
  auto r=read32(flush_address_);
  if(r.outcome==mailbox::Outcome::Completed && r.value!=expected_)r.outcome=mailbox::Outcome::Unknown;
  return r;
 }
};
}
extern "C" int run_startup(int *result){
 Port provision(768,0xa10e0001),closure(836,8),fence(512,1),command(592,0);
 asus::a10::control::ClosedStartup s({{{&provision,768},{&closure,832},{&fence,512},{&command,576}}},{9,0,1,2,3,4},1);
 while(s.result()==0)s.advance();
 *result=s.result()==1?0:1;
 if(!*result)std::puts("KERNEL_STARTUP_RTL_ACCEPTED");
 else std::printf("HOST_CLOSED_STARTUP_FAILURE result=%d\n",s.result());
 return 0;
}
