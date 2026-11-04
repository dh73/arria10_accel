/* SPDX-License-Identifier: BSD-3-Clause */
#include <assert.h>
#include <stdio.h>
#include "../aclpci_supervisor_command.h"
struct model { u64 previous, id, returned; u32 op, reason; unsigned calls, fail, commits, mask; int flushed, busy, reject, bad_id, bad_reason; };
static int done(struct model *m) { return ++m->calls == m->fail ? -5 : 0; }
static int read_word(void *p, unsigned o, u32 *v)
{
    struct model *m=p; u64 id=m->commits?m->returned:m->previous;
    switch(o) {
    case 16:*v=m->busy?1:m->commits?(m->reject?2:6):0;break;
    case 24:*v=(u32)id;break;
    case 28:*v=(u32)(id>>32);break;
    case 20:*v=m->bad_reason?8:m->reason;break;
    default:assert(0);
    }
    return done(m);
}
static int write_word(void *p, unsigned o, u32 v)
{
    struct model *m=p;
    switch(o) {
    case 0:m->id=v;m->mask|=1;break;
    case 4:m->id|=(u64)v<<32;m->mask|=2;break;
    case 8:m->op=v;m->mask|=4;break;
    case 12:assert(v==0xa10c0001 && m->mask==7 && m->flushed);
        m->commits++;m->returned=m->id+(m->bad_id?1:0);break;
    default:assert(0);
    }
    return done(m); /* Includes failure after a real side effect. */
}
static int flush(void *p) { struct model *m=p;m->flushed=1;return done(m); }
int main(void)
{
    unsigned op,fail,i,case_id;
    for(op=0;op<3;op++)for(fail=0;fail<=12;fail++) {
        struct model m={.fail=fail};struct aclpci_supervisor_command c;
        struct aclpci_fence_io io={&m,read_word,write_word,flush};
        assert(!aclpci_supervisor_command_init(&c,0x100000002ULL,op));
        for(i=0;i<(fail?fail:12);i++)aclpci_supervisor_command_step(&c,&io);
        assert(c.result==(fail?-5:1) && m.commits<=1);
        if(!fail)assert(m.id==0x100000002ULL && m.op==op);
        i=m.calls;aclpci_supervisor_command_step(&c,&io);assert(m.calls==i);
    }
    for(case_id=0;case_id<7;case_id++) {
        struct model m={0};struct aclpci_supervisor_command c;
        struct aclpci_fence_io io={&m,read_word,write_word,flush};
        if(case_id==0)m.previous=4;
        if(case_id==1)m.bad_id=1;
        if(case_id==2)m.bad_reason=1;
        if(case_id==3){m.reject=1;m.reason=3;}
        if(case_id==4)m.busy=1;
        if(case_id==5)m.reason=3;
        if(case_id==6)m.reject=1;
        assert(!aclpci_supervisor_command_init(&c,4,0));
        if(case_id==4){assert(!aclpci_supervisor_command_step(&c,&io));assert(!m.mask);m.busy=0;}
        for(i=0;i<12;i++)aclpci_supervisor_command_step(&c,&io);
        { const int expected[]={-116,-116,-5,2,1,-5,-5};
          assert(c.result==expected[case_id]); }
        if(case_id==0)assert(!m.mask && !m.commits);
    }
    {struct aclpci_supervisor_command c;assert(aclpci_supervisor_command_init(&c,0,0)<0);assert(aclpci_supervisor_command_init(&c,1,3)<0);}
    puts("KERNEL_SUPERVISOR_COMMAND_PASS operations=3 uncertain_boundaries=12 stale_identity rejection busy invalid no_retry");
}
