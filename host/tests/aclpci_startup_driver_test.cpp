#include "aclpci_startup_client.hpp"
#include <cassert>
#include <iostream>
extern "C" {
void startup_fixture_begin(int);
long startup_fixture_io(void*,unsigned long,int);
void startup_fixture_finish(int);
}
using C=asus::a10::AclPciStartupClient;
unsigned calls;
ssize_t io(int fd,void* p,std::size_t n,bool reading) noexcept {
 assert(fd==91);++calls;return startup_fixture_io(p,n,reading);
}
int main(){
 const std::array<std::uint32_t,6> context{1,2,3,4,5,6};
 for(int boundary=-1;boundary<82;++boundary){
  startup_fixture_begin(boundary);calls=0;C c(91,io);
  assert(c.arm(context,0x800000007ULL)==C::State::Pending);
  for(unsigned step=0;step<82 && c.state()==C::State::Pending;++step)c.advance();
  assert(c.state()==(boundary<0?C::State::Accepted:C::State::Unknown));
  auto before=calls;c.advance();c.arm(context,1);assert(calls==before);
  startup_fixture_finish(boundary<0);
 }
 std::cout<<"STARTUP_CLIENT_DRIVER_PASS success reset_boundaries=82 no_replay admission_blocked\n";
}
