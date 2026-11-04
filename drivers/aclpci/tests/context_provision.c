/* SPDX-License-Identifier: BSD-3-Clause */
#include "aclpci_dma_test_kernel.h"
#include "../aclpci_context_provision.c"
struct fixture { unsigned calls,fail,commits,status,corrupt; int error; u32 words[6]; };
static int finish(struct fixture *f) { return ++f->calls == f->fail ? f->error : 0; }
static int read_word(void *raw, unsigned off, u32 *v)
{
    struct fixture *f=raw;
    assert(!(off&3) && off<32);
    *v=off==0?0xa10e0001:off==4?f->status:f->words[(off-8)/4];
    if(off>=8 && (off-8)/4==f->corrupt)*v^=1;
    return finish(f);
}
static int write_word(void *raw,unsigned off,u32 v)
{
    struct fixture *f=raw; assert(!f->status);
    if(!off) { assert(v==0xa10e0001);f->status=1;++f->commits; }
    else {assert(off>=8&&off<32&&!(off&3));f->words[(off-8)/4]=v;}
    return finish(f);
}
static int flush(void *raw) { return finish(raw); }
int main(void)
{
    const u32 words[6]={1,2,3,4,5,6};unsigned n,i;
    for(n=0;n<=19;++n) {
        struct fixture f={.fail=n,.error=-EIO,.corrupt=99};
        struct aclpci_fence_io io={&f,read_word,write_word,flush};
        struct aclpci_context_provision c; int result;
        assert(!aclpci_context_provision_init(&c,words));
        for(i=0;i<19;++i)result=aclpci_context_provision_step(&c,&io);
        assert(result==(n?-EIO:1));assert(f.calls==(n?n:19)&&f.commits<=1);
        assert(aclpci_context_provision_step(&c,&io)==result);
        assert(f.calls==(n?n:19));
    }
    for(n=0;n<6;++n) {
        struct fixture f={.corrupt=n};struct aclpci_fence_io io={&f,read_word,write_word,flush};struct aclpci_context_provision c;
        assert(!aclpci_context_provision_init(&c,words));
        for(i=0;i<19;++i)aclpci_context_provision_step(&c,&io);
        assert(c.result==-EIO);
    }
    {struct fixture f={.status=1};struct aclpci_fence_io io={&f,read_word,write_word,flush};struct aclpci_context_provision c;
     assert(!aclpci_context_provision_init(&c,words));for(i=0;i<19;++i)aclpci_context_provision_step(&c,&io);
     assert(c.result==-EIO&&f.calls==2&&!f.commits);}
    puts("CONTEXT_KERNEL_PROTOCOL_PASS boundaries=19 readback=6 no_replay existing_owner");return 0;
}
