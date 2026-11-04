/* SPDX-License-Identifier: BSD-3-Clause */
#define main retained_integration_suites
#include "integration.c"
#undef main

static struct file client_fd;
static unsigned steps;
static int revoke_at;
void startup_fixture_begin(int boundary)
{
    const u32 context[6]={1,2,3,4,5,6};
    u32 *p,*u,*f;
    init_engine();device.io_blocked=true;
    device.bar[2]=bar4;device.bar_length[2]=sizeof bar4;
    memset(bar4,0,sizeof bar4);
    p=bar4+ACLPCI_PLATFORM_CONTEXT_BASE/4;
    u=bar4+ACLPCI_PLATFORM_CLOSURE_BASE/4;
    f=bar4+ACLPCI_PLATFORM_FENCE_BASE/4;
    p[0]=0xa10e0001;u[0]=0xa10b0001;u[1]=8;
    memcpy(u+2,context,sizeof context);u[8]=1;
    f[0]=1;memcpy(f+1,context,sizeof context);f[7]=1;
    client_fd.private_data=&file;steps=0;revoke_at=boundary;
}
long startup_fixture_io(void *cmd, unsigned long n, int reading)
{
    unsigned before=test.mmio_reads+test.mmio_writes;
    long result;
    if(reading) {
        struct aclpci_startup *s=&device.control_startup;
        u32 *p=bar4+ACLPCI_PLATFORM_CONTEXT_BASE/4;
        u32 *u=bar4+ACLPCI_PLATFORM_CLOSURE_BASE/4;
        u32 *f=bar4+ACLPCI_PLATFORM_FENCE_BASE/4;
        u32 *c=bar4+ACLPCI_PLATFORM_COMMAND_BASE/4;
        if(s->phase==0 && s->provision.step>=10)p[1]=1;
        if(s->closure.step>=20)u[1]=9;
        if(s->fence.step)assert(s->closure.result==1);
        if(s->phase==1 && s->fence.step==6)f[0]=3;
        if(s->phase==2 && s->command.step>=8){c[4]=6;c[6]=7;c[7]=8;}
        if((int)steps==revoke_at)aclpci_dma_revoke(&device);
        ++steps;
    }
    result=reading?aclpci_read(&client_fd,cmd,n,NULL):aclpci_write(&client_fd,cmd,n,NULL);
    assert(test.mmio_reads+test.mmio_writes<=before+1);
    assert(device.io_blocked); /* START never grants DMA admission. */
    return result;
}
void startup_fixture_finish(int accepted)
{
    assert((device.control_startup.result==1)==!!accepted);
    down(&device.sem);
    if(device.control_debt)assert(aclpci_control_release_unused(&file)==-EBUSY);
    /* Fixture disposal only. No production drain or release is asserted. */
    device.control_debt=false;assert(!aclpci_control_release_unused(&file));
    up(&device.sem);assert(!aclpci_dma_finish(&device));assert(!test.live_allocs);
}
