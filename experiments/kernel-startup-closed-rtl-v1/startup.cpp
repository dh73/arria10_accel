#include <cstdio>
extern "C" {
#include "aclpci_startup.h"
int startup_get(unsigned long long,unsigned*);
int startup_put(unsigned long long,unsigned);
}
namespace {
struct Window { unsigned base,flush_offset; };
int read(void *raw,unsigned offset,u32 *value) {
 auto& w=*static_cast<Window*>(raw);return startup_get(w.base+offset,value);
}
int write(void *raw,unsigned offset,u32 value) {
 auto& w=*static_cast<Window*>(raw);return startup_put(w.base+offset,value);
}
int flush(void *raw) {
 auto& w=*static_cast<Window*>(raw);u32 value=0;
 int error=read(raw,w.flush_offset,&value);
 if(error)return error;
 if(w.base==768)return value==0xa10e0001?0:-5;
 if(w.base==832)return value==8?0:-5;
 if(w.base==512)return value==1?0:-5;
 return value==0||value==2||value==6?0:-5;
}
}
extern "C" int run_startup(int *result) {
 *result=1;
 Window u{832,4},p{768,0},f{512,0},c{576,16};
 const aclpci_fence_io ui{&u,read,write,flush};
 const aclpci_fence_io pi{&p,read,write,flush},fi{&f,read,write,flush},ci{&c,read,write,flush};
 const u32 context[6]={9,0,1,2,3,4};
 aclpci_startup request;
 if(aclpci_startup_closed_init(&request,context,1))return 0;
 while(!request.result)aclpci_startup_closed_step(&request,&pi,&ui,&fi,&ci);
 if(request.result!=1)std::printf("CLOSED_STARTUP_FAILURE result=%d phase=%u provision=%u closure=%u fence=%u command=%u\n",request.result,request.phase,request.provision.step,request.closure.step,request.fence.step,request.command.step);
 if(request.result==1){*result=0;std::puts("KERNEL_STARTUP_RTL_ACCEPTED");}
 return 0;
}
