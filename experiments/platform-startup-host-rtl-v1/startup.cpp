#include "platform_startup.hpp"
#include <cstdio>
extern "C" int startup_get(unsigned long long,unsigned*);
extern "C" int startup_put(unsigned long long,unsigned);
using namespace asus::a10;
namespace {
class Port final:public mailbox::Port {
 std::uint64_t base_;
 public: explicit Port(std::uint64_t b):base_(b){}
 mailbox::Reply read32(std::uint64_t a)noexcept override {unsigned v;startup_get(a,&v);return{mailbox::Outcome::Completed,v};}
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v)noexcept override {startup_put(a,v);return{mailbox::Outcome::Completed};}
 mailbox::Reply fence()noexcept override{return read32(base_+20);}
};
}
extern "C" int run_startup(int* result){
 *result=1;Port provision(768),fence(512),command(576);
 control::Startup request(provision,768,fence,512,command,576,9,{0x200000001ull,0x400000003ull},1);
 while(request.state()==control::State::Pending)request.advance();
 if(request.state()==control::State::Accepted&&request.next_round()==2){*result=0;std::puts("CXX_STARTUP_RTL_ACCEPTED");}
 return 0;
}
