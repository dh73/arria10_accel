#include "platform_context_provision.hpp"
#include <cassert>
#include <iostream>
using namespace asus::a10;
struct Port final:mailbox::Port{
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
 using context::Provision;using context::State;
 for(auto e:{mailbox::Outcome::Unknown,mailbox::Outcome::NotIssued})for(unsigned n=0;n<=19;++n){
  Port p;p.fail=n;p.error=e;Provision c(p,768,0x200000001,{0x400000003,0x600000005});
  for(unsigned i=0;i<19;++i)c.advance();
  assert(c.state()==(n?State::Poisoned:State::Complete));
  auto calls=p.calls;c.advance();assert(calls==p.calls&&p.commits<=1);
  if(!n)assert((p.published==std::array<std::uint32_t,6>{1,2,3,4,5,6}));
 }
 for(unsigned status:{1u,2u,3u,4u}){Port p;p.status=status;Provision c(p,768,1,{1,0});for(int i=0;i<19;++i)c.advance();assert(c.state()==State::Rejected&&p.calls==2&&!p.commits);}
 for(unsigned w=0;w<6;++w){Port p;p.corrupt=w;Provision c(p,768,1,{1,0});for(int i=0;i<19;++i)c.advance();assert(c.state()==State::Rejected);}
 {Port p;Provision c(p,768,1,{1,0});for(int i=0;i<18;++i)c.advance();p.status=2;c.advance();assert(c.state()==State::Rejected);}
 {Port p;p.wrong_magic=true;Provision c(p,768,1,{1,0});c.advance();assert(c.state()==State::Rejected&&!p.commits);}
 for(auto base:{769ull,~0ull-3}){Port p;Provision c(p,base,1,{1,0});c.advance();assert(c.state()==State::Rejected&&!p.calls);}
 {Port p;Provision a(p,768,0,{1,0}),b(p,768,1,{0,0});a.advance();b.advance();assert(a.state()==State::Rejected&&b.state()==State::Rejected&&!p.calls);}
 std::cout<<"CONTEXT_PROVISION_PASS boundaries=19 immutable_readback no_replay final_fault\n";
}
