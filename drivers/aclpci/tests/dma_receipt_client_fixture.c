/* SPDX-License-Identifier: BSD-3-Clause */
#define main retained_integration_suites
#include "integration.c"
#undef main
static struct file client_fd;
void receipt_fixture_begin(void) {
    poll_table waiter = {0};
    init_engine();client_fd.private_data=&file;
    assert(!aclpci_poll(&client_fd,&waiter));
    assert(file.dma_completion_wait.registrations==1);
}
long receipt_fixture_read(void *cmd, unsigned long bytes) {
    long result=aclpci_read(&client_fd,cmd,bytes,NULL);
    if (device.dma_data.active) assert(!aclpci_poll(&client_fd,NULL));
    return result;
}
void receipt_fixture_submit(void) {
    struct acl_cmd cmd = { .bar_id=ACLPCI_CMD_BAR, .command=ACLPCI_CMD_DMA_SUBMIT,
      .device_addr=(void *)0x200000, .user_addr=(void *)0x100000, .size=4 };
    unsigned before=test.doorbells;
    assert(!aclpci_read(&client_fd,(char *)&cmd,sizeof cmd,NULL));
    assert(device.dma_data.active && test.doorbells==before+1);
}
void receipt_fixture_irq_without_status(void) {
    unsigned wakes=file.dma_completion_wait.wakes;
    aclpci_dma_service_interrupt(&device);run_work();
    assert(file.dma_completion_wait.wakes==wakes);
    assert(!aclpci_poll(&client_fd,NULL));
    assert(device.dma_data.active);
}
void receipt_fixture_stop(void) {
    assert(aclpci_dma_stop(&device)==-EINPROGRESS);
    assert(device.dma_data.active);
}
void receipt_fixture_complete(void) {
    unsigned wakes=file.dma_completion_wait.wakes;
    assert(!aclpci_poll(&client_fd,NULL));
    complete_with_irq();assert(!device.dma_data.active);
    assert(file.dma_completion_wait.wakes==wakes+1);
    assert(aclpci_poll(&client_fd,NULL)==(EPOLLIN|EPOLLRDNORM));
    assert(test.unmaps && test.unpins);
    assert(!test.signal_count); /* Explicit DMA is event/receipt-only. */
}
void receipt_fixture_finish(void) { finish_engine(); }

long receipt_fixture_write(void *cmd, unsigned long bytes) {
    long result=aclpci_write(&client_fd,cmd,bytes,NULL);
    if (device.dma_data.active) assert(!aclpci_poll(&client_fd,NULL));
    return result;
}

/* Read-only identity fixture for the real command path, with DMA disabled. */
void receipt_fixture_identity(void) {
    u32 *identity=bar4+ACLPCI_PLATFORM_IDENTITY_BASE/4;
    device.io_blocked=true;device.dma_data.contract_valid=false;
    device.bar[2]=bar4;device.bar_length[2]=sizeof bar4;
    memset(bar4,0,sizeof bar4);
    identity[0]=ACLPCI_ID_MAGIC;identity[1]=ACLPCI_ID_V2;identity[2]=2;
    identity[3]=256;identity[4]=identity[5]=31;identity[6]=7;
}
