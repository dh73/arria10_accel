/* SPDX-License-Identifier: BSD-3-Clause */
#define main retained_integration_suites
#include "integration.c"
#undef main
static struct file client_fd;
void receipt_fixture_begin(void) {
    init_engine();client_fd.private_data=&file;
}
long receipt_fixture_read(void *cmd, unsigned long bytes) {
    return aclpci_read(&client_fd,cmd,bytes,NULL);
}
void receipt_fixture_submit(void) {
    struct acl_cmd cmd = { .bar_id=ACLPCI_CMD_BAR, .command=ACLPCI_CMD_DMA_SUBMIT,
      .device_addr=(void *)0x200000, .user_addr=(void *)0x100000, .size=4 };
    unsigned before=test.doorbells;
    assert(!aclpci_read(&client_fd,(char *)&cmd,sizeof cmd,NULL));
    assert(device.dma_data.active && test.doorbells==before+1);
}
void receipt_fixture_irq_without_status(void) {
    aclpci_dma_service_interrupt(&device);run_work();
    assert(device.dma_data.active);
}
void receipt_fixture_stop(void) {
    assert(aclpci_dma_stop(&device)==-EINPROGRESS);
    assert(device.dma_data.active);
}
void receipt_fixture_complete(void) {
    complete_with_irq();assert(!device.dma_data.active);
    assert(test.unmaps && test.unpins);
}
void receipt_fixture_finish(void) { finish_engine(); }

long receipt_fixture_write(void *cmd, unsigned long bytes) {
    return aclpci_write(&client_fd,cmd,bytes,NULL);
}
