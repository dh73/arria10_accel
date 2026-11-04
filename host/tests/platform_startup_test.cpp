#include "platform_startup.hpp"
#include "host_writeback_round.hpp"
#include <cassert>
#include <iostream>
using namespace asus::a10;
struct Model final:mailbox::Port {
 std::array<std::uint32_t,8> words{1,2,3,4,5,6,1,0},echo{};
 unsigned calls=0,fail=0,commits=0,mask=0;
 bool ready=true,settled=false,flushed=false;
 mailbox::Outcome failure=mailbox::Outcome::Unknown;
 std::array<std::uint32_t,6> context()const{return {words[0],words[1],words[2],words[3],words[4],words[5]};}
 mailbox::Reply done(std::uint32_t v=0) {
  ++calls;return {calls==fail?failure:mailbox::Outcome::Completed,v};
 }
 mailbox::Reply read32(std::uint64_t a) noexcept override {
  assert(a>=0x1000&&a<=0x1020&&!(a&3));
  return done(a==0x1000?(settled?3:ready?1:0):words[(a-0x1004)/4]);
 }
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v) noexcept override {
  if(a==0x1024){assert(v==0xa10f0001&&mask==255&&flushed&&echo==words);++commits;settled=true;}
  else {assert(a>=0x1004&&a<=0x1020&&!(a&3));unsigned i=(a-0x1004)/4;echo[i]=v;mask|=1u<<i;}
  return done(); // Failure injection may happen after side effects.
 }
 mailbox::Reply fence() noexcept override {flushed=true;return done();}
};
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

struct ProvisionPort final:mailbox::Port{
 unsigned calls=0,fail=0,commits=0,status=0,corrupt=99;bool wrong_magic=false;
 mailbox::Outcome error=mailbox::Outcome::Unknown;
 std::array<std::uint32_t,6> staged{},published{};
 mailbox::Reply done(unsigned v=0){return{++calls==fail?error:mailbox::Outcome::Completed,v};}
 mailbox::Reply read32(std::uint64_t a)noexcept override{
  assert(a>=768&&a<800&&!(a&3));unsigned off=unsigned(a-768);
  if(off==0)return done(wrong_magic?0:0xa10e0001);
  if(off==4)return done(status);
  unsigned i=(off-8)/4;return done(published[i]^(i==corrupt?1:0));
 }
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v)noexcept override{
  assert(!status);if(a==768){assert(v==0xa10e0001);++commits;published=staged;status=1;}
  else {assert(a>=776&&a<800&&!(a&3));staged[(a-776)/4]=v;}
  return done();
 }
 mailbox::Reply fence()noexcept override{return done();}
};
int main(){
 using control::Startup;using control::State;
 for(unsigned boundary=0;boundary<=52;++boundary){
  ProvisionPort p;Model f;Port c;
  if(boundary<=19)p.fail=boundary;
  else if(boundary<=40)f.fail=boundary-19;
  else c.fail=boundary-40;
  Startup r(p,768,f,0x1000,c,0,0x200000001,{0x400000003,0x600000005},1);
  for(unsigned i=0;i<52;++i){
   auto before=p.calls+f.calls+c.calls;r.advance();
   assert(p.calls+f.calls+c.calls<=before+1);
   if(p.calls<19)assert(!f.calls&&!c.calls);
   if(f.calls<21)assert(!c.calls);
  }
  assert(r.state()==(boundary?State::Poisoned:State::Accepted));
  assert(bool(r.next_round())==!boundary);
  if(!boundary)assert(*r.next_round()==2&&p.commits==1&&f.commits==1&&c.commits==1);
  auto before=p.calls+f.calls+c.calls;r.advance();assert(before==p.calls+f.calls+c.calls);
 }
 {ProvisionPort p;Model f;Port c;Startup r(p,768,f,0x1000,c,0,1,{1,0},0);r.advance();assert(r.state()==State::Poisoned&&!p.calls&&!f.calls&&!c.calls);}
 {ProvisionPort p;p.status=1;Model f;Port c;Startup r(p,768,f,0x1000,c,0,1,{1,0},1);for(int i=0;i<52;++i)r.advance();assert(r.state()==State::Rejected&&!f.calls&&!c.calls);}
 std::cout<<"PLATFORM_STARTUP_PASS boundaries=52 provisioning_before_fence_before_start no_replay\n";
}
