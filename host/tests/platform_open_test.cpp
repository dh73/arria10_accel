#include "platform_open.hpp"
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

int main(){
 using control::OpenRequest;using control::State;using control::Command;
 for(auto cmd:{Command::Start,Command::Resume}){
  Model f;Port c;OpenRequest r(f,0x1000,c,0,f.context(),1,1,cmd);
  for(unsigned i=0;i<21;i++){r.advance();assert(c.calls==0&&!r.next_round());}
  for(unsigned i=0;i<12;i++)r.advance();
  assert(r.state()==State::Accepted&&r.next_round()==2&&f.commits==1&&c.commits==1);
  const auto calls=f.calls+c.calls;r.advance();assert(f.calls+c.calls==calls);
 }
 for(auto outcome:{mailbox::Outcome::Unknown,mailbox::Outcome::NotIssued})
  for(unsigned boundary=1;boundary<=33;boundary++){
   Model f;Port c;f.failure=c.outcome=outcome;
   if(boundary<=21)f.fail=boundary;else c.fail=boundary-21;
   OpenRequest r(f,0x1000,c,0,f.context(),1,1,Command::Start);
   for(unsigned i=0;i<boundary;i++)r.advance();
   assert(r.state()==State::Poisoned&&!r.next_round());
   if(boundary<=21)assert(c.calls==0);
   auto calls=f.calls+c.calls;r.advance();assert(calls==f.calls+c.calls);
  }
 {Model f;Port c;c.reason=5;OpenRequest r(f,0x1000,c,0,f.context(),1,1,Command::Start);
  for(unsigned i=0;i<33;i++)r.advance();
  assert(r.state()==State::Rejected&&r.reason()==5&&!r.next_round());}
 for(auto cmd:{Command::Quiesce,static_cast<Command>(3)}){
  Model f;Port c;OpenRequest r(f,0x1000,c,0,f.context(),1,1,cmd);
  assert(r.advance()==State::Poisoned&&f.calls==0&&c.calls==0);}
 {Model f;Port c;OpenRequest r(f,0x1000,c,0,f.context(),~std::uint64_t(0),1,Command::Resume);
  assert(r.advance()==State::Poisoned&&f.calls==0&&c.calls==0);}
 {Model f;Port c;f.ready=false;OpenRequest r(f,0x1000,c,0,f.context(),1,1,Command::Start);
  assert(r.advance()==State::Pending&&f.calls==1&&c.calls==0);
  f.ready=true;for(unsigned i=0;i<33;i++)r.advance();assert(r.next_round()==2);}
 {Model f;Port c;f.words[6]=2;OpenRequest r(f,0x1000,c,0,f.context(),1,1,Command::Resume);
  for(unsigned i=0;i<10;i++)r.advance();
  assert(r.state()==State::Poisoned&&c.calls==0&&!r.next_round());}
 std::cout<<"PLATFORM_OPEN_HOST_PASS boundaries=33 outcomes=2 command_after_fence no_replay rejected stale_round no_wrap\n";
}
