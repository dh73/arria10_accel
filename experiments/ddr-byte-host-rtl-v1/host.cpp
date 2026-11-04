#include "ddr_byte_write.hpp"
extern "C" {int byte_get(unsigned long long,unsigned*);int byte_put(unsigned long long,unsigned);}
using namespace asus::a10;
class Port final:public mailbox::Port {
 public:
 mailbox::Reply read32(std::uint64_t a)noexcept override{unsigned v=0;auto rc=byte_get(a,&v);return {rc?mailbox::Outcome::Unknown:mailbox::Outcome::Completed,v};}
 mailbox::Reply write32(std::uint64_t a,std::uint32_t v)noexcept override{return {byte_put(a,v)?mailbox::Outcome::Unknown:mailbox::Outcome::Completed,0};}
 mailbox::Reply fence()noexcept override{return read32(1024);}
};
extern "C" int byte_host(int* result){
 Port port;unsigned sequence=0;*result=1;
 for(unsigned slot=0;slot<16;++slot)for(unsigned mask=1;mask<16;++mask){
  ++sequence;memory::ByteWrite op(port,1024,0x80000000,0x1000+4*slot,0xa1b2c3d4^sequence,mask,sequence);
  while(op.state()==memory::WriteState::Progress||op.state()==memory::WriteState::AwaitingCompletion)op.advance();
  if(op.state()!=memory::WriteState::Complete)return 0;
 }
 *result=0;return 0;
}
