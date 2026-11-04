#include "kernel_mailbox.hpp"
#include <cstdint>
#include <cstdio>
#include <stdexcept>
using namespace asus::a10::mailbox;
extern "C" int mailbox_put(unsigned long long,unsigned int);
extern "C" int mailbox_get(unsigned long long,unsigned int*);
struct RtlPort : Port {
 static constexpr std::uint64_t base=0x100000000ull;
 bool lose_command_ack=false;
 unsigned calls=0;
 Reply write32(std::uint64_t a,std::uint32_t v) noexcept override {
  ++calls; if(mailbox_put(a,v)) return {Outcome::Unknown};
  if(lose_command_ack && a==base+16) return {Outcome::Unknown};
  return {Outcome::Completed};
 }
 Reply read32(std::uint64_t a) noexcept override {
  ++calls; unsigned int v=0;
  if(mailbox_get(a,&v)) return {Outcome::Unknown};
  return {Outcome::Completed,v};
 }
 Reply fence() noexcept override { return read32(base+20); }
};
void require(bool b) { if(!b)throw std::runtime_error("host/RTL mailbox mismatch"); }
void complete(Sequencer& s) {
 // Native simulation service loop; all device calls advance the SV clocks.
 while(s.state()==State::Pending)s.advance();
 require(s.state()==State::Completed);
}
extern "C" int run_mailbox_host(int* result) {
 *result=1;
 try {
  RtlPort p;Sequencer s(p,RtlPort::base);
  require(s.begin(1,128,false,0xaabbccddeeff0011ull,0x35));complete(s);
  require(s.begin(2,128,true));complete(s);require(s.value()==0x1122ccdd55ff7711ull);
  require(s.begin(3,128,true));complete(s);require(s.value()==0);
  auto n=p.calls;s.advance();require(p.calls==n);require(!s.begin(3,128,true));
  p.lose_command_ack=true;
  require(s.begin(4,8,false,1));
  while(s.state()==State::Pending)s.advance();
  require(s.state()==State::Poisoned);n=p.calls;s.advance();
  require(p.calls==n && !s.begin(5,8,false,1));
  *result=0;
 }catch(const std::exception& e){std::fprintf(stderr,"MAILBOX_HOST_RTL_FAILURE %s\n",e.what());}
 return 0;
}
