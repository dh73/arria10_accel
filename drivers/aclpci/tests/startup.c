/* SPDX-License-Identifier: BSD-3-Clause */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <linux/errno.h>
#include "../aclpci_startup.h"
struct model {
    unsigned calls, fail, phase, bound, settled, started, reject;
    int error;
    u32 context[6], echo[8];
    u64 id;
};
struct window { struct model *m; unsigned phase; };
static int done(struct model *m) { return ++m->calls == m->fail ? m->error : 0; }
static void check(struct window *w) {
    assert(w->phase >= w->m->phase); w->m->phase=w->phase;
    if(w->phase>0) assert(w->m->bound);
    if(w->phase>1) assert(w->m->settled);
}
static int read_word(void *raw,unsigned off,u32 *v) {
    struct window *w=raw; struct model *m=w->m; check(w);
    if(w->phase==0) {
        assert(off<32 && !(off&3));
        *v=off==0?0xa10e0001:off==4?m->bound:m->context[(off-8)/4];
    } else if(w->phase==1) {
        assert(off<=32 && !(off&3));
        *v=off==0?(m->settled?3:1):off<=24?m->context[(off-4)/4]:off==28?1:0;
    } else {
        assert(off==16||off==20||off==24||off==28);
        *v=off==16?(m->started?(m->reject?2:6):0):off==20?m->reject:
           off==24?(m->started?(u32)m->id:0):(m->started?(u32)(m->id>>32):0);
    }
    return done(m);
}
static int write_word(void *raw,unsigned off,u32 v) {
    struct window *w=raw;struct model *m=w->m;check(w);
    if(w->phase==0) {
        assert(!m->bound);
        if(!off) {assert(v==0xa10e0001);m->bound=1;}
        else {assert(off>=8&&off<32&&!(off&3));m->context[(off-8)/4]=v;}
    } else if(w->phase==1) {
        if(off==36) {
            assert(v==0xa10f0001&&!m->settled);
            assert(!memcmp(m->echo,m->context,sizeof m->context));
            assert(m->echo[6]==1&&!m->echo[7]);m->settled=1;
        } else {assert(off>=4&&off<=32&&!(off&3));m->echo[(off-4)/4]=v;}
    } else {
        if(off==0)m->id=v;
        else if(off==4)m->id|=(u64)v<<32;
        else if(off==8)assert(v==0);
        else {assert(off==12&&v==0xa10c0001&&m->id&&!m->started);m->started=1;}
    }
    return done(m); /* Failure can follow the actual side effect. */
}
static int flush(void *raw) {struct window *w=raw;check(w);return done(w->m);}
int main(void) {
    const u32 context[6]={1,2,3,4,5,6};unsigned fail,i,mode;
    for(mode=0;mode<3;++mode)for(fail=0;fail<=52;++fail) {
        struct model m={.fail=fail,.error=mode==1?1:-EIO,.reject=mode==2?3:0};
        struct window w[3]={{&m,0},{&m,1},{&m,2}};
        struct aclpci_fence_io io[3];struct aclpci_startup s;
        for(i=0;i<3;++i)io[i]=(struct aclpci_fence_io){&w[i],read_word,write_word,flush};
        assert(!aclpci_startup_init(&s,context,0x100000002ull));
        for(i=0;i<54;++i) {
            unsigned before=m.calls;
            aclpci_startup_step(&s,&io[0],&io[1],&io[2]);
            assert(m.calls<=before+1);
        }
        assert(s.result==(fail?-EIO:mode==2?2:1));
        assert(m.calls==(fail?fail:52));
        assert(aclpci_startup_step(&s,NULL,NULL,NULL)==s.result);
        assert(m.calls==(fail?fail:52));
    }
    {struct aclpci_startup s;
     assert(aclpci_startup_init(&s,context,0)==-EINVAL);
     assert(aclpci_startup_step(&s,NULL,NULL,NULL)==-EINVAL);
     assert(aclpci_startup_init(&s,NULL,1)==-EINVAL);}
    /* Revoke before every I/O boundary and after accepted/rejected START.
     * Each case retains all side effects, then must perform no further I/O. */
    for(mode=0;mode<2;++mode)for(fail=0;fail<=52;++fail) {
        struct model m={.reject=mode?3:0};
        struct window w[3]={{&m,0},{&m,1},{&m,2}};
        struct aclpci_fence_io io[3];struct aclpci_startup s;
        for(i=0;i<3;++i)io[i]=(struct aclpci_fence_io){&w[i],read_word,write_word,flush};
        assert(!aclpci_startup_init(&s,context,1));
        for(i=0;i<fail;++i)aclpci_startup_step(&s,&io[0],&io[1],&io[2]);
        assert(m.calls==fail);
        assert(aclpci_startup_revoke(&s)==-ESTALE);
        for(i=0;i<54;++i)assert(aclpci_startup_step(&s,&io[0],&io[1],&io[2])==-ESTALE);
        assert(m.calls==fail && aclpci_startup_revoke(&s)==-ESTALE);
    }
    {struct aclpci_startup s;
     assert(aclpci_startup_init(&s,NULL,1)==-EINVAL);
     assert(aclpci_startup_revoke(&s)==-EINVAL);
     assert(aclpci_startup_revoke(NULL)==-EINVAL);}
    puts("KERNEL_STARTUP_PASS boundaries=52 modes=3 ordered_stages terminal_no_replay");
    puts("KERNEL_STARTUP_REVOKE_PASS boundaries=53 outcomes=2 no_io_after_revoke");
    return 0;
}
