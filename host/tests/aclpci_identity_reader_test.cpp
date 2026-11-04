#include "aclpci_identity_reader.hpp"
#include "pcie_linux_driver_exports.h"
#include <cstdlib>
#include <iostream>
using namespace asus::a10::image;
#define CHECK(c) do { if(!(c)) std::abort(); } while(false)
unsigned calls=0;ssize_t response=0;
ssize_t io(int fd,void* p,std::size_t n,bool reading) noexcept {
 ++calls;auto& c=*static_cast<acl_cmd*>(p);
 CHECK(fd==91 && reading && n==4 && c.size==4 && c.bar_id==2 && c.command==0 && c.is_diff_endian==0);
 auto a=reinterpret_cast<std::uintptr_t>(c.device_addr);
 CHECK(a>=256 && a<512 && !(a&3));
 *static_cast<std::uint32_t*>(c.user_addr)=static_cast<std::uint32_t>(a);return response;
}
int main(){
 AclPciReader r(91,256,7,io);
 for(unsigned i=0;i<64;++i){auto v=r.read32({7,i+1,i*4});CHECK(v.completed && v.value==256+i*4 && v.request.channel==7 && v.request.serial==i+1 && v.request.offset==i*4);}
 CHECK(!r.read32({7,64,0}).completed);auto before=calls;CHECK(!r.read32({7,65,0}).completed && calls==before);
 for(auto q:{Request{8,1,0},Request{7,0,0},Request{7,1,1},Request{7,1,256}}){
  AclPciReader bad(91,256,7,io);before=calls;CHECK(!bad.read32(q).completed && calls==before);
  CHECK(!bad.read32({7,2,0}).completed && calls==before);
 }
 for(auto rc:{ssize_t(-1),ssize_t(1),ssize_t(4)}){
  response=rc;AclPciReader bad(91,256,7,io);CHECK(!bad.read32({7,1,0}).completed);before=calls;
  CHECK(!bad.read32({7,2,0}).completed && calls==before);
 }
 response=0;AclPciReader overflow(91,~std::uint64_t(3),7,io);before=calls;
 CHECK(!overflow.read32({7,1,0}).completed && calls==before);
 std::cout<<"ACLPCI_IDENTITY_READER_PASS\n";
}
