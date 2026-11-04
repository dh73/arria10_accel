#include "kernel_mailbox.hpp"
#include <cstdlib>
#include <iostream>
#include <utility>
#include <vector>
using namespace asus::a10::mailbox;
#define CHECK(x) do { if (!(x)) { std::cerr << "failure " << __LINE__ << '\n'; std::abort(); } } while(false)
struct Model : Port {
  static constexpr std::uint64_t base=0x123400000000ull;
  unsigned calls=0, fail_at=0, commands=0, reads=0, busy=0;
  Outcome failure=Outcome::Unknown;
  bool execute_unknown=false;
  std::uint32_t regs[8]{};
  std::vector<std::pair<unsigned,std::uint32_t>> posted;
  std::uint64_t cra=0x1122334455667788ull;
  Reply check() { return {++calls==fail_at?failure:Outcome::Completed}; }
  Reply write32(std::uint64_t a,std::uint32_t v) noexcept override {
    CHECK(a>=base && a<base+32 && !(a&3));
    auto r=check(); if(r.outcome==Outcome::Completed || (r.outcome==Outcome::Unknown && execute_unknown)) posted.emplace_back((a-base)/4,v);
    return r;
  }
  Reply fence() noexcept override {
    auto r=check(); if(r.outcome!=Outcome::Completed && !(r.outcome==Outcome::Unknown && execute_unknown)) return r;
    for(auto [index,v]:posted) {
      if(index!=4) { regs[index]=v; continue; }
      CHECK(regs[0]==128); ++commands; busy=2; regs[5]=1;
      if(v==2) { ++reads; regs[6]=std::uint32_t(cra); regs[7]=cra>>32; cra=0; }
      else {
        CHECK(v==1);
        const auto data=std::uint64_t(regs[1])|(std::uint64_t(regs[2])<<32);
        for(unsigned b=0;b<8;++b) if(regs[3]&(1u<<b)) {
          const auto m=std::uint64_t(255)<<(8*b); cra=(cra&~m)|(data&m);
        }
      }
    }
    posted.clear(); return r;
  }
  Reply read32(std::uint64_t a) noexcept override {
    CHECK(a>=base && a<base+32 && !(a&3)); auto r=check();
    if(r.outcome!=Outcome::Completed && !(r.outcome==Outcome::Unknown && execute_unknown)) return r;
    if(a==base+20 && busy && --busy==0) regs[5]=2;
    r.value=regs[(a-base)/4]; return r;
  }
};
void finish(Sequencer& s) {
  // Finite model test guard, not an execution deadline or production poller.
  unsigned steps=0;
  while(s.state()==State::Pending) { CHECK(++steps<32); s.advance(); }
}
int main() {
  Model m; Sequencer s(m,Model::base);
  CHECK(!s.begin(0,128,false)); CHECK(!s.begin(1,129,false));
  CHECK(!s.begin(1,512,false)); CHECK(!s.begin(1,128,false,0,0)); CHECK(m.calls==0);
  CHECK(s.begin(1,128,false,0xaabbccddeeff0011ull,0x35));
  CHECK(!s.begin(2,128,true)); finish(s); CHECK(s.state()==State::Completed);
  CHECK(m.cra==0x1122ccdd55ff7711ull); CHECK(m.commands==1);
  CHECK(!s.begin(1,128,true)); CHECK(s.begin(2,128,true)); finish(s);
  CHECK(s.state()==State::Completed && s.value()==0x1122ccdd55ff7711ull);
  CHECK(m.reads==1 && m.cra==0); auto calls=m.calls;
  s.advance(); CHECK(m.calls==calls); CHECK(!s.begin(2,128,true));
  // Every I/O boundary: no command replay or device access after uncertainty.
  for(bool execute_unknown:{false,true}) for(bool read:{false,true}) for(Outcome failure:{Outcome::Unknown,Outcome::NotIssued}) {
    Model ref; Sequencer good(ref,Model::base); CHECK(good.begin(1,128,read,42)); finish(good);
    for(unsigned boundary=1;boundary<=ref.calls;++boundary) {
      Model f; f.fail_at=boundary; f.failure=failure; f.execute_unknown=execute_unknown; Sequencer q(f,Model::base);
      CHECK(q.begin(1,128,read,42)); finish(q);
      CHECK(q.state()==State::Poisoned || q.state()==State::NotIssued);
      if(failure==Outcome::Unknown) CHECK(q.state()==State::Poisoned);
      CHECK(f.commands<=1); const auto n=f.calls; q.advance(); CHECK(n==f.calls);
      if(q.state()==State::Poisoned) CHECK(!q.begin(2,128,read));
    }
  }
  for(unsigned bad:{1u,3u,4u,6u,0xffffffffu}) {
    Model f; f.regs[5]=bad; Sequencer q(f,Model::base);
    CHECK(q.begin(1,128,true)); q.advance(); CHECK(q.state()==State::Poisoned && f.commands==0);
  }
  std::cout<<"MAILBOX_HOST_PASS\n";
}
