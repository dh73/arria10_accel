#include "host_writeback_fence.hpp"
#include <cassert>
#include <iostream>
using namespace asus::a10;
struct Model final:mailbox::Port {
 std::array<std::uint32_t,6> words{1,2,3,4,5,6},echo{};
 unsigned calls=0,fail=0,commits=0,mask=0;bool ready=true,settled=false,flushed=false;
 mailbox::Reply done(std::uint32_t v=0) {
  ++calls;return {calls==fail?mailbox::Outcome::Unknown:mailbox::Outcome::Completed,v};
 }
 mailbox::Reply read32(std::uint64_t a) noexcept override {
  assert(a>=0x1000&&a<0x1020&&!(a&3));
  return done(a==0x1000?(settled?3:ready?1:0):words[(a-0x1004)/4]);
 }
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v) noexcept override {
  if(a==0x101c){assert(v==0xa10f0001&&mask==63&&flushed&&echo==words);++commits;settled=true;}
  else {unsigned i=(a-0x1004)/4;assert(i<6);echo[i]=v;mask|=1u<<i;}
  return done();
 }
 mailbox::Reply fence() noexcept override {flushed=true;return done();}
};
int main() {
 using writeback::Fence;using writeback::State;
 Model reference;Fence ok(reference,0x1000,reference.words);
 // Seventeen I/O steps are prescribed by this finite protocol path.
 for(unsigned i=0;i<17;i++)ok.advance();
 assert(ok.state()==State::Settled&&reference.calls==17&&reference.commits==1);
 for(unsigned fail=1;fail<=17;fail++) {
  Model m;m.fail=fail;Fence f(m,0x1000,m.words);
  for(unsigned i=0;i<fail;i++)f.advance();
  assert(f.state()==State::Poisoned&&m.commits<=1);
  f.advance();assert(m.calls==fail);
 }
 for(unsigned word=0;word<6;word++) {
  Model m;auto context=m.words;context[word]^=16;Fence f(m,0x1000,context);
  for(unsigned i=0;i<8;i++)f.advance();
  assert(f.state()==State::Poisoned&&m.mask==0&&m.commits==0);
 }
 Model pending;pending.ready=false;Fence p(pending,0x1000,pending.words);
 assert(p.advance()==State::Pending&&pending.calls==1&&pending.mask==0);
 pending.ready=true;
 for(unsigned i=0;i<17;i++)p.advance();
 assert(p.state()==State::Settled&&pending.commits==1);
 Model invalid;Fence bad(invalid,~0ull,invalid.words);
 assert(bad.advance()==State::Poisoned&&invalid.calls==0);
 std::cout<<"HOST_WRITEBACK_SEQUENCER_PASS boundaries=17 mismatches=6\n";
}
