#include "platform_closed_startup.hpp"
#include <cassert>
#include <cerrno>
#include <cstdio>
using namespace asus::a10;
struct Port final:mailbox::Port {
 unsigned calls=0,fail=0,phase=0;
 bool bound=false,closed=false,settled=false,started=false;
 std::uint32_t context[6]={},echo[8]={};std::uint64_t id=0;
 mailbox::Reply finish(std::uint32_t value=0) {
  return {++calls==fail?mailbox::Outcome::Unknown:mailbox::Outcome::Completed,value};
 }
 void select(unsigned p){assert(p>=phase);phase=p;if(p>0)assert(bound);if(p>1)assert(closed);if(p>2)assert(settled);}
 mailbox::Reply read32(std::uint64_t a)noexcept override {
  unsigned p=a/256,o=a%256;select(p);std::uint32_t v=0;
  if(p==0)v=o==0?0xa10e0001:o==4?bound:context[(o-8)/4];
  if(p==1)v=o==0?0xa10b0001:o==4?(closed?9:8):o<32?context[(o-8)/4]:o==32?1:0;
  if(p==2)v=o==0?(settled?3:1):o<=24?context[(o-4)/4]:o==28?1:0;
  if(p==3)v=o==16?(started?6:0):o==20?0:o==24?std::uint32_t(id):std::uint32_t(id>>32);
  return finish(v);
 }
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v)noexcept override {
  unsigned p=a/256,o=a%256;select(p);
  if(p==0){if(!o){assert(v==0xa10e0001);bound=true;}else context[(o-8)/4]=v;}
  if(p==1||p==2){unsigned commit=p==1?40:36,base=p==1?8:4;
   if(o==commit){for(unsigned i=0;i<6;++i)assert(echo[i]==context[i]);assert(echo[6]==1&&echo[7]==0);if(p==1)closed=true;else settled=true;}
   else echo[(o-base)/4]=v;
  }
  if(p==3){if(!o)id=v;else if(o==4)id|=std::uint64_t(v)<<32;else if(o==8)assert(!v);else {assert(o==12&&v==0xa10c0001);started=true;}}
  return finish();
 }
 mailbox::Reply fence()noexcept override{return finish();}
};
int main(){
 for(unsigned fail=0;fail<=82;++fail){
  Port p;p.fail=fail;
  control::ClosedStartup s({{{&p,0},{&p,256},{&p,512},{&p,768}}},{1,2,3,4,5,6},0x100000002ull);
  for(unsigned i=0;i<84;++i){auto n=p.calls;s.advance();assert(p.calls<=n+1);}
  assert(s.result()==(fail?-EIO:1));assert(p.calls==(fail?fail:82));
  auto n=p.calls;assert(s.advance()==s.result()&&p.calls==n);
  assert(s.revoke()<0);s.advance();assert(p.calls==n);
 }
 Port p;
 control::ClosedStartup bad({{{&p,0},{&p,UINT64_MAX},{&p,512},{&p,768}}},{1,2,3,4,5,6},1);
 assert(bad.advance()==-EINVAL&&p.calls==0);
 std::puts("CLOSED_STARTUP_HOST_PASS 82 uncertain boundaries, ordered stages, revocation, overflow");
}
