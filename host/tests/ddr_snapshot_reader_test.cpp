#include "ddr_snapshot_reader.hpp"
#include <cassert>
#include <iostream>
using namespace asus::a10;
struct Port final:mailbox::Port{
 unsigned calls=0,fail=0,captures=0,change_at=0;std::uint64_t seq=0;
 unsigned flags=1,magic=0xa10d0001;
 mailbox::Outcome error=mailbox::Outcome::Unknown;
 mailbox::Reply done(unsigned v=0){++calls;if(calls==change_at)++seq;return{calls==fail?error:mailbox::Outcome::Completed,v};}
 mailbox::Reply read32(std::uint64_t a)noexcept override{
  assert(a>=640&&a<=708&&a%4==0);auto off=a-640;
  auto v=off==0?magic:off==4?flags:off==8?unsigned(seq):off==12?unsigned(seq>>32):unsigned(off-16+100);
  return done(v);
 }
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v)noexcept override{assert(a==640&&v==0xa10d0001);++captures;++seq;return done();}
 mailbox::Reply fence()noexcept override{return done();}
};
int main(){
 using metrics::Capture;using metrics::CaptureState;
 constexpr std::array<std::uint64_t,4> ctx{1,2,3,4};
 for(auto outcome:{mailbox::Outcome::Unknown,mailbox::Outcome::NotIssued})for(unsigned n=0;n<=24;++n){
  Port p;p.fail=n;p.error=outcome;Capture c(p,640,ctx);
  for(unsigned i=0;i<(n?n:24);++i)c.advance();
  assert(c.state()==(n?CaptureState::Poisoned:CaptureState::Complete));
  auto calls=p.calls;c.advance();assert(p.calls==calls&&p.captures<=1);
  if(!n){auto s=c.snapshot();assert(s&&s->sequence==1&&s->context==ctx&&s->counts[0]==(std::uint64_t(104)<<32|100));}
  else assert(!c.snapshot());
 }
 for(unsigned at=6;at<=22;++at){Port p;p.change_at=at;Capture c(p,640,ctx);for(int i=0;i<24;++i)c.advance();assert(c.state()==CaptureState::Rejected&&!c.snapshot());}
 // A new snapshot after the final low-word read does not tear the old sample.
 {Port p;p.change_at=23;Capture c(p,640,ctx);for(int i=0;i<24;++i)c.advance();assert(c.state()==CaptureState::Complete&&c.snapshot()->sequence==1);}
 // Sequence rollover during a high/low/high stamp must be rejected.
 {Port p;p.seq=0xfffffffe;p.change_at=4;Capture c(p,640,ctx);for(int i=0;i<24;++i)c.advance();assert(c.state()==CaptureState::Rejected);}
 for(unsigned flags:{0u,3u,5u,9u}){Port p;p.flags=flags;Capture c(p,640,ctx);for(int i=0;i<24;++i)c.advance();assert(c.state()==CaptureState::Rejected);}
 {Port p;p.magic=0;Capture c(p,640,ctx);c.advance();assert(c.state()==CaptureState::Rejected&&!p.captures);}
 {Port p;Capture c(p,641,ctx);c.advance();assert(c.state()==CaptureState::Rejected&&!p.calls);}
 std::cout<<"DDR_CAPTURE_PASS io_boundaries=24 torn_reads=17 rollover invalid_flags no_replay\n";
}
