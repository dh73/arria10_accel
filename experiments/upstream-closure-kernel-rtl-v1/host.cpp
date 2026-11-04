#include <cstdio>
extern "C" {
#include "aclpci_upstream_closure.h"
int closure_reset();
int closure_get(unsigned,unsigned*);
int closure_put(unsigned,unsigned);
int closure_reopen(unsigned long long);
}
namespace {
unsigned calls,fail,commits;
int finish(){return ++calls==fail?-5:0;}
int read(void*,unsigned off,u32* v){closure_get(off,v);return finish();}
int write(void*,unsigned off,u32 v){closure_put(off,v);if(off==40)++commits;return finish();}
int flush(void*){unsigned v;closure_get(4,&v);int e=finish();return e?e:v==8?0:-5;}
const aclpci_fence_io io{nullptr,read,write,flush};
const u32 context[6]={9,0xfedcba98,1,2,3,4};
bool complete(unsigned long long round){
 aclpci_upstream_closure c;
 if(aclpci_upstream_closure_init(&c,context,round))return false;
 while(!c.result)aclpci_upstream_closure_step(&c,&io);
 return c.result==1;
}
}
extern "C" int run_closure(int* result){
 *result=1;
 closure_reset();calls=fail=commits=0;
 if(!complete(1)||calls!=30||commits!=1)return 0;
 closure_reopen(1);
 if(!complete(2)||calls!=60||commits!=2)return 0;
 closure_reopen(2);
 if(complete(1)||commits!=2)return 0; // Old round must fail before commit.
 for(unsigned boundary=1;boundary<=30;++boundary){
  closure_reset();calls=commits=0;fail=boundary;
  aclpci_upstream_closure c;
  if(aclpci_upstream_closure_init(&c,context,1))return 0;
  while(!c.result)aclpci_upstream_closure_step(&c,&io);
  if(c.result>=0||calls!=boundary||commits>1)return 0;
  const unsigned before=calls;
  aclpci_upstream_closure_step(&c,&io);
  if(calls!=before)return 0;
  unsigned status;closure_get(4,&status);
  if(status!=(boundary>=20?9u:8u))return 0;
 }
 std::puts("UPSTREAM_CLOSURE_KERNEL_RTL_PASS boundaries=30 rounds=2 stale_round no_replay");*result=0;return 0;
}
