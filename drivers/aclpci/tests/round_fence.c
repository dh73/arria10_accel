/* SPDX-License-Identifier: BSD-3-Clause */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../aclpci_round_fence.h"
struct model { u32 words[8], echo[8]; unsigned calls, fail, mask, commits; int ready, settled, flushed; };
static int done(struct model *m) { return ++m->calls == m->fail ? -5 : 0; }
static int read_word(void *ctx, unsigned off, u32 *v)
{
    struct model *m = ctx;
    assert(off <= 32 && !(off & 3));
    *v = off ? m->words[(off-4)/4] : m->settled ? 3u : (u32)m->ready;
    return done(m);
}
static int write_word(void *ctx, unsigned off, u32 v)
{
    struct model *m = ctx;
    if (off == 36) {
        assert(v == 0xa10f0001 && m->mask == 255 && m->flushed);
        assert(!memcmp(m->words, m->echo, sizeof(m->words)));
        m->commits++; m->settled = 1;
    } else {
        assert(off >= 4 && off <= 32 && !(off & 3));
        m->echo[(off-4)/4] = v; m->mask |= 1u << ((off-4)/4);
    }
    return done(m); /* Error may follow a real write side effect. */
}
static int flush(void *ctx) { struct model *m=ctx; m->flushed=1; return done(m); }
static struct model fresh(void) { struct model m={ .words={1,2,3,4,5,6,1,0}, .ready=1 }; return m; }
int main(void)
{
    unsigned n,i;
    for (n=0;n<=21;n++) {
        struct model m=fresh(); struct aclpci_round_fence f;
        struct aclpci_fence_io io={&m,read_word,write_word,flush};
        m.fail=n; assert(!aclpci_round_fence_init(&f,m.words,1));
        for (i=0;i<(n?n:21);i++) aclpci_round_fence_step(&f,&io);
        assert(f.result==(n?-5:1) && m.commits<=1);
        i=m.calls; aclpci_round_fence_step(&f,&io); assert(m.calls==i);
    }
    for (n=0;n<8;n++) {
        struct model m=fresh(); struct aclpci_round_fence f;
        struct aclpci_fence_io io={&m,read_word,write_word,flush};
        assert(!aclpci_round_fence_init(&f,m.words,1)); m.words[n]^=16;
        for(i=0;i<10;i++) aclpci_round_fence_step(&f,&io);
        assert(f.result<0 && !m.mask && !m.commits);
    }
    {
        struct model m=fresh(); struct aclpci_round_fence f;
        struct aclpci_fence_io io={&m,read_word,write_word,flush};
        m.ready=0; assert(!aclpci_round_fence_init(&f,m.words,1));
        assert(!aclpci_round_fence_step(&f,&io) && m.calls==1);
        m.ready=1;for(i=0;i<21;i++)aclpci_round_fence_step(&f,&io);assert(f.result==1);
        assert(aclpci_round_fence_init(&f,m.words,0)<0);
        i=m.calls;assert(aclpci_round_fence_step(&f,&io)<0 && m.calls==i);
    }
    puts("KERNEL_ROUND_FENCE_HOST_PASS uncertain_boundaries=21 context_mismatch=8 no_retry");
    return 0;
}
