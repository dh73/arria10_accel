#include "aclpci_identity_snapshot.hpp"
#include "pcie_linux_driver_exports.h"
#include <cassert>
#include <iostream>
extern "C" {
void receipt_fixture_begin();void receipt_fixture_identity();void receipt_fixture_finish();
long receipt_fixture_read(void*,unsigned long);
}
static unsigned mode,calls;
static ssize_t reader(int fd,void* p,std::size_t n){
 assert(fd==91);++calls;
 auto* cmd=static_cast<acl_cmd*>(p);auto* words=static_cast<std::uint32_t*>(cmd->user_addr);
 auto result=receipt_fixture_read(p,n);assert(result==0);
 if(mode==1)words[1]=1;
 if(mode==2)++words[67];
 if(mode==3)return -1;
 return result;
}
int main(){
 using namespace asus::a10;
 receipt_fixture_begin();receipt_fixture_identity();
 for(mode=0;mode<4;++mode){
  auto value=read_identity_snapshot(91,reader);assert(calls==mode+1);
  auto code=mode==0?image::Code::Consistent:mode==1?image::Code::Malformed:
            mode==2?image::Code::Torn:image::Code::IoFailure;
  assert(value.code==code);
  if(!mode)assert(value.raw.before==7&&value.raw.after==7&&value.raw.words[0]==ACLPCI_ID_MAGIC);
 }
 receipt_fixture_finish();
 std::cout<<"IDENTITY_SNAPSHOT_DRIVER_PASS stable malformed torn io_error one_call\n";
}
