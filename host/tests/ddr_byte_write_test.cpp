#include "ddr_byte_write.hpp"
#include <cassert>
#include <iostream>
#include <vector>
using namespace asus::a10;
struct Port:mailbox::Port {
 unsigned calls=0,fail=~0u,commands=0;bool complete=false,stale=false;
 std::vector<std::pair<std::uint64_t,std::uint32_t>> writes;
 mailbox::Reply result(std::uint32_t value=0){return {calls++==fail?mailbox::Outcome::Unknown:mailbox::Outcome::Completed,value};}
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v)noexcept override{
  writes.emplace_back(a,v);if(a==1052){assert(v==1);++commands;}return result();
 }
 mailbox::Reply read32(std::uint64_t a)noexcept override{
  assert(a==1024||a==1028||a==1056);
  return result(a==1024?0x42595701:a==1028?(commands?(complete?4:1):0):(commands?(stale?0:1):0));
 }
 mailbox::Reply fence()noexcept override{return result();}
};
int main(){
 using W=memory::ByteWrite;using S=memory::WriteState;
 Port p;W w(p,1024,0x80000000,0x7ffffffc,0xaabbccdd,5,1);
 while(w.state()==S::Progress)w.advance();
 assert(w.state()==S::AwaitingCompletion&&p.commands==1&&w.command_attempted());
 const std::vector<std::pair<std::uint64_t,std::uint32_t>> expected={{1032,0x7ffffffc},{1036,0},{1040,0xaabbccdd},{1044,5},{1048,1},{1052,1}};
 assert(p.writes==expected);p.complete=true;
 while(w.state()==S::Progress||w.state()==S::AwaitingCompletion)w.advance();
 assert(w.state()==S::Complete&&p.commands==1);auto calls=p.calls;w.advance();assert(calls==p.calls);
 for(unsigned failure=0;failure<13;++failure){
  Port q;q.fail=failure;q.complete=true;W x(q,1024,0x80000000,0x3000,1,1,1);
  while(x.state()==S::Progress)x.advance();
  assert(x.state()==S::Unknown);auto n=q.calls;x.advance();assert(q.calls==n&&q.commands<=1);
 }
 Port q;q.complete=true;q.stale=true;W stale(q,1024,0x80000000,0,1,1,1);
 while(stale.state()==S::Progress)stale.advance();assert(stale.state()==S::Unknown);
 Port bad;W invalid(bad,1024,0x80000000,0x80000000,1,1,1);assert(invalid.advance()==S::Rejected&&!bad.calls);
 std::cout<<"DDR_BYTE_WRITE_HOST_PASS ordered command_once delayed_completion stale_id failures=13 bounds\n";
}
