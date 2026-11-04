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
int main() {
 using writeback::RoundFence;using writeback::State;
 Model reference;RoundFence ok(reference,0x1000,reference.context(),1);
 for(unsigned i=0;i<21;i++)ok.advance();
 assert(ok.state()==State::Settled&&reference.calls==21&&reference.commits==1);
 for(auto outcome:{mailbox::Outcome::Unknown,mailbox::Outcome::NotIssued})
  for(unsigned fail=1;fail<=21;fail++) {
   Model m;m.fail=fail;m.failure=outcome;RoundFence f(m,0x1000,m.context(),1);
   for(unsigned i=0;i<fail;i++)f.advance();
   assert(f.state()==State::Poisoned&&m.commits<=1);
   f.advance();assert(m.calls==fail);
  }
 for(unsigned word=0;word<8;word++) {
  Model m;const auto context=m.context();m.words[word]^=16;
  RoundFence f(m,0x1000,context,1);
  for(unsigned i=0;i<10;i++)f.advance();
  assert(f.state()==State::Poisoned&&m.mask==0&&m.commits==0);
 }
 // Actual device is in round two: an old instance must not echo any words.
 Model next;next.words[6]=2;RoundFence stale(next,0x1000,next.context(),1);
 for(unsigned i=0;i<10;i++)stale.advance();
 assert(stale.state()==State::Poisoned&&next.mask==0);
 RoundFence current(next,0x1000,next.context(),2);
 for(unsigned i=0;i<21;i++)current.advance();
 assert(current.state()==State::Settled&&next.commits==1);
 // Exercise the high round word independently of the immutable epoch.
 Model high;high.words[6]=0;high.words[7]=1;
 RoundFence wide(high,0x1000,high.context(),1ull<<32);
 for(unsigned i=0;i<21;i++)wide.advance();assert(wide.state()==State::Settled);
 Model pending;pending.ready=false;RoundFence p(pending,0x1000,pending.context(),1);
 assert(p.advance()==State::Pending&&pending.calls==1&&pending.mask==0);
 pending.ready=true;for(unsigned i=0;i<21;i++)p.advance();assert(p.state()==State::Settled);
 for(auto base:{0x1001ull,~0ull-35}) {
  Model m;RoundFence f(m,base,m.context(),1);assert(f.advance()==State::Poisoned&&m.calls==0);
 }
 Model invalid;RoundFence zero(invalid,0x1000,invalid.context(),0);
 assert(zero.advance()==State::Poisoned&&invalid.calls==0);
 std::cout<<"HOST_WRITEBACK_ROUND_SEQUENCER_PASS boundaries=21 outcomes=2 mismatches=8 stale_round high_round\n";
}
