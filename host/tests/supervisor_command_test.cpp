#include "supervisor_command.hpp"
#include <cassert>
#include <iostream>
using namespace asus::a10;
struct Port final:mailbox::Port {
 unsigned calls=0,fail=0,commits=0,mask=0;bool flushed=false;
 std::uint64_t previous=0,id=0,result=0;unsigned status=0,reason=0,op=0;
 mailbox::Outcome outcome=mailbox::Outcome::Unknown;
 mailbox::Reply done(unsigned value=0){++calls;return {calls==fail?outcome:mailbox::Outcome::Completed,value};}
 mailbox::Reply read32(std::uint64_t a)noexcept override{
  assert(a==16||a==20||a==24||a==28);
  auto v=a==16?status:a==20?reason:a==24?std::uint32_t(result):std::uint32_t(result>>32);return done(v);
 }
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v)noexcept override{
  if(a==0){id=(id&0xffffffff00000000ull)|v;mask|=1;}
  else if(a==4){id=(id&0xffffffffull)|(std::uint64_t(v)<<32);mask|=2;}
  else if(a==8){op=v;mask|=4;}
  else {assert(a==12&&v==0xa10c0001&&mask==7&&flushed&&id>previous);++commits;previous=id;result=id;status=reason?2:6;}
  return done();
 }
 mailbox::Reply fence()noexcept override{flushed=true;return done();}
};
int main(){
 using control::Request;using control::State;using control::Command;
 for(unsigned reason:{0u,5u}){
  Port p;p.reason=reason;Request r(p,0,0x100000002ull,Command::Start);
  for(unsigned i=0;i<12;i++)r.advance();
  assert(r.state()==(reason?State::Rejected:State::Accepted)&&r.reason()==reason&&p.commits==1);
 }
 for(auto outcome:{mailbox::Outcome::Unknown,mailbox::Outcome::NotIssued})
  for(unsigned n=1;n<=12;n++){
   Port p;p.fail=n;p.outcome=outcome;Request r(p,0,2,Command::Quiesce);
   for(unsigned i=0;i<n;i++)r.advance();assert(r.state()==State::Poisoned&&p.calls==n);
   r.advance();assert(p.calls==n&&p.commits<=1);
  }
 Port stale;stale.result=stale.previous=9;stale.status=6;Request old(stale,0,9,Command::Resume);
 for(int i=0;i<3;i++)old.advance();assert(old.state()==State::Poisoned&&stale.mask==0);
 Port foreign;Request r(foreign,0,2,Command::Start);for(int i=0;i<9;i++)r.advance();
 foreign.result=3;for(int i=0;i<3;i++)r.advance();assert(r.state()==State::Poisoned);
 Port pending;pending.status=1;Request waiting(pending,0,1,Command::Start);
 assert(waiting.advance()==State::Pending&&pending.calls==1&&pending.mask==0);
 pending.status=0;for(int i=0;i<12;i++)waiting.advance();assert(waiting.state()==State::Accepted);
 Port invalid;Request zero(invalid,0,0,Command::Start);assert(zero.advance()==State::Poisoned&&invalid.calls==0);
 std::cout<<"SUPERVISOR_HOST_PASS boundaries=12 outcomes=2 stale_previous foreign_result rejection high_id\n";
}
