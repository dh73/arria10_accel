/* SPDX-License-Identifier: BSD-3-Clause */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <linux/errno.h>
#include "../aclpci_upstream_closure.h"
struct model {u32 words[8],echo[8];unsigned calls,fail,mask,commits,status;int error;};
static int done(struct model *m) {return ++m->calls==m->fail?m->error:0;}
static int read_word(void *raw,unsigned off,u32 *value) {
 struct model *m=raw;assert(off<=36&&!(off&3));
 *value=off==0?0xa10b0001:off==4?m->status:m->words[(off-8)/4];return done(m);
}
static int write_word(void *raw,unsigned off,u32 value) {
 struct model *m=raw;assert(!m->commits);
 if(off==40){assert(value==0xa10b0001&&m->mask==255&&!memcmp(m->words,m->echo,sizeof m->words));m->status=9;++m->commits;}
 else {assert(off>=8&&off<=36&&!(off&3));m->echo[(off-8)/4]=value;m->mask|=1u<<((off-8)/4);}
 return done(m); /* An uncertain write can already have taken effect. */
}
static int flush(void *raw) {return done(raw);}
int main(void) {
 const u32 context[6]={9,0xfedcba98,1,2,3,4};unsigned fail,i,mode;
 for(mode=0;mode<2;++mode)for(fail=0;fail<=30;++fail) {
  struct model m={.words={9,0xfedcba98,1,2,3,4,1,0},.fail=fail,.error=mode?1:-EIO,.status=8};
  struct aclpci_fence_io io={&m,read_word,write_word,flush};struct aclpci_upstream_closure c;
  assert(!aclpci_upstream_closure_init(&c,context,1));
  for(i=0;i<32;++i){unsigned before=m.calls;aclpci_upstream_closure_step(&c,&io);assert(m.calls<=before+1);}
  assert(c.result==(fail?-EIO:1)&&m.calls==(fail?fail:30)&&m.commits<=1);
 }
 for(mode=0;mode<2;++mode)for(i=0;i<8;++i) {
  struct model m={.words={9,0xfedcba98,1,2,3,4,1,0},.status=8};
  struct aclpci_fence_io io={&m,read_word,write_word,flush};struct aclpci_upstream_closure c;
  assert(!aclpci_upstream_closure_init(&c,context,1));
  if(mode)for(fail=0;fail<21;++fail)assert(!aclpci_upstream_closure_step(&c,&io));
  m.words[i]^=1;
  for(fail=0;fail<32;++fail)aclpci_upstream_closure_step(&c,&io);
  assert(c.result==-ESTALE&&m.commits==mode);
  if(!mode)assert(!m.mask);
 }
 puts("UPSTREAM_CLOSURE_KERNEL_PASS boundaries=30 full_context no_replay stale_before_and_after_commit");return 0;
}
