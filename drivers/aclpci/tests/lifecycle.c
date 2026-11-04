/* SPDX-License-Identifier: BSD-3-Clause */
#define ACLPCI_LIFECYCLE_TEST
/* Avoid the libc remove(path) name; only the included driver's symbol moves. */
#include "aclpci_lifecycle_test_kernel.h"
#define remove driver_remove
#include "../aclpci.c"
#undef remove

static struct pci_dev endpoint(struct pci_bus *bus)
{
    struct pci_dev p = {0};

    p.vendor = ACL_PCI_ALTERA_VENDOR_ID;
    p.class = ACL_PCI_CLASSCODE;
    p.subsystem_vendor = ACL_PCI_SUBSYSTEM_VENDOR_ID;
    p.subsystem_device = ACL_PCI_SUBSYSTEM_DEVICE_ID;
    p.refs = 1;
    p.irq = 173;
    p.bus = bus;
    p.lengths[0] = 0x1000;
    p.lengths[4] = 0x20000;
    return p;
}

static void clean_counters(void)
{
    assert(!heap_objects && !cdev_objects && !node_objects && !mapped_bars);
    assert(!dma_objects && !irq_requested && !module_refs);
    injected = FAIL_NONE;
    test_contract = false;
    map_calls = queued = notifications = writes = 0;
    order_count = 0;
    order[0] = 0;
}

static void check_unwound(struct pci_dev *p, struct pci_dev *upstream)
{
    assert(!p->enabled && !p->regions && !p->msi && !p->master && !p->data);
    assert(p->refs == 1 && upstream->refs == 1);
    assert(!heap_objects && !cdev_objects && !node_objects && !mapped_bars);
    assert(!dma_objects && !irq_requested);
    for (unsigned int i = 0; i < ACLPCI_MAX_MINORS; ++i)
        assert(!aclpci_devices[i]);
}

static void faults(void)
{
    struct pci_dev bridge = { .refs = 1 };
    struct pci_bus bus = { .self = &bridge };

    for (enum fault f = FAIL_STATE; f <= FAIL_IRQ; ++f) {
        struct pci_dev p = endpoint(&bus);
        int error;

        clean_counters();
        injected = f;
        test_contract = f == FAIL_MSI || f == FAIL_IRQ;
        error = probe(&p, &aclpci_ids[0]);
        assert(error < 0);
        check_unwound(&p, &bridge);
        if (f == FAIL_IRQ)
            assert(strchr(order, 'I')); /* MSI undone on request_irq failure. */
    }
    clean_counters();
    struct pci_dev short_bar = endpoint(&bus);
    short_bar.lengths[4] = PCIE_CRA_IRQ_ENABLE;
    assert(probe(&short_bar, &aclpci_ids[0]) == -ENODEV);
    check_unwound(&short_bar, &bridge);
    puts("PASS lifecycle probe/allocation/MSI/IRQ/publication unwind (14 faults)");
}

static void blocked_and_references(void)
{
    struct pci_dev bridge = { .refs = 1 };
    struct pci_bus bus = { .self = &bridge };
    struct pci_dev p = endpoint(&bus);
    struct aclpci_dev *a, *held;
    struct cdev wrong = {0};

    clean_counters();
    p.subsystem_device = 0xa151;
    assert(probe(&p, &aclpci_ids[0]) == -ENODEV);
    assert(!heap_objects && !writes);
    p.subsystem_device = ACL_PCI_SUBSYSTEM_DEVICE_ID;
    assert(probe(&p, &aclpci_ids[0]) == 0);
    a = p.data;
    assert(a->online && a->io_blocked && !a->dma_data.contract_valid);
    assert(!p.master && !irq_requested && !writes);
    assert(init_irq(&p, a) == -EOPNOTSUPP);
    assert(!aclpci_get_by_minor(MINOR(a->cdev_num), &wrong));
    held = aclpci_get_by_minor(MINOR(a->cdev_num), a->cdev);
    assert(held == a && a->ref.refs == 2);
    driver_remove(&p);
    assert(!a->online && a->removed && a->io_blocked);
    assert(!p.data && !p.enabled && !dma_objects && !mapped_bars);
    assert(a->ref.refs == 1 && heap_objects == 2);
    assert(!aclpci_get_by_minor(0, &wrong));
    aclpci_put(held);
    check_unwound(&p, &bridge);
    clean_counters();
    puts("PASS blocked admission, narrow match and surviving offline file reference");
}

static void irq_order_and_kernel_once(void)
{
    struct pci_dev bridge = { .refs = 1 };
    struct pci_bus bus = { .self = &bridge };
    struct pci_dev p = endpoint(&bus);
    struct task_struct task = { .refs = 1 };
    struct aclpci_dev *a;
    u32 status = 1;

    clean_counters();
    test_contract = true; /* Test double supplies the missing shell contract. */
    assert(probe(&p, &aclpci_ids[0]) == 0);
    a = p.data;
    assert(irq_requested && p.msi && registered_irq == 173);
    assert(a->irq_line == 22); /* Never use PCI_INTERRUPT_LINE for free_irq. */
    assert(init_irq(&p, a) == 0);
    aclpci_set_signal_task(a, &task);
    assert(task.refs == 2);
    unmask_kernel_irq(a);
    memcpy(a->bar[4] + PCIE_CRA_IRQ_STATUS, &status, sizeof(status));
    assert(registered_handler(173, a) == IRQ_HANDLED);
    assert(registered_handler(173, a) == IRQ_HANDLED);
    assert(notifications == 1 && task.refs == 2 && queued == 2);
    unmask_kernel_irq(a);
    assert(registered_handler(173, a) == IRQ_HANDLED);
    assert(notifications == 2 && queued == 3);
    p.disconnected = true;
    unsigned int before = writes;
    assert(registered_handler(173, a) == IRQ_NONE && writes == before);
    p.disconnected = false;
    p.frozen = true;
    mask_irq(a);
    mask_kernel_irq(a);
    unmask_kernel_irq(a);
    assert(registered_handler(173, a) == IRQ_NONE && writes == before);
    assert(queued == 3 && notifications == 2);
    p.frozen = false;
    a->online = false;
    assert(registered_handler(173, a) == IRQ_NONE && writes == before);
    a->online = true;
    status = UINT32_MAX;
    memcpy(a->bar[4] + PCIE_CRA_IRQ_STATUS, &status, sizeof(status));
    assert(registered_handler(173, a) == IRQ_NONE && queued == 3);
    order_count = 0;
    order[0] = 0;
    driver_remove(&p);
    assert(strstr(order, "TMSFID")); /* stop, mask, sync, free, MSI off, finish */
    assert(task.refs == 1);
    check_unwound(&p, &bridge);
    clean_counters();
    puts("PASS IRQ init/release ordering, exact IRQ number and one kernel signal per arm");
}

static void retained_remove(bool control_debt)
{
    struct pci_dev bridge = { .refs = 1 };
    struct pci_bus bus = { .self = &bridge };
    struct pci_dev p = endpoint(&bus);
    struct aclpci_dev *a;

    clean_counters();
    test_contract = true;
    assert(probe(&p, &aclpci_ids[0]) == 0);
    a = p.data;
    a->dma_data.active = !control_debt;
    a->control_debt = control_debt;
    module_refs = 1; /* The request's independent file context module pin. */
    order_count = 0;
    order[0] = 0;
    driver_remove(&p);
    assert(a->quarantined && a->removed && !a->online);
    assert(p.data == a && p.enabled && p.regions && p.master);
    assert(!irq_requested && !p.msi && !node_objects && !cdev_objects);
    assert(dma_objects == 3 && mapped_bars == 2 && heap_objects == 2);
    assert(a->ref.refs == 1 && p.refs == 2 && bridge.refs == 2);
    assert(module_refs == 2 && strstr(order, control_debt ? "TMSFIQ" : "TMSFIDQ"));
    assert(probe(&p, &aclpci_ids[0]) == -EBUSY);
    struct pci_dev rescan = endpoint(&bus);
    assert(probe(&rescan, &aclpci_ids[0]) == -EBUSY);
    assert(!rescan.data && rescan.refs == 1);
    unsigned int retained_order = order_count;
    driver_remove(&p);
    assert(order_count == retained_order); /* no repeated free or quarantine */

    /* Only mock fixture disposal, not an exported production reclaim path.
     * The production driver cannot establish this physical-drain fact. */
    a->dma_data.active = false;
    assert(aclpci_dma_finish(a) == 0);
    list_del(&a->quarantine_link);
    free_bars(a, &p);
    pci_release_regions(&p);
    pci_disable_device(&p);
    pci_clear_master(&p);
    pci_set_drvdata(&p, NULL);
    aclpci_put(a);
    module_refs = 0;
    check_unwound(&p, &bridge);
    clean_counters();
    puts("PASS unknown remove retains mappings/context/resources and blocks reprobe");
}

int main(void)
{
    assert(aclpci_init() == 0);
    faults();
    blocked_and_references();
    irq_order_and_kernel_once();
    retained_remove(false);
    retained_remove(true);
    aclpci_exit();
    return 0;
}
