/* SPDX-License-Identifier: BSD-3-Clause */
#include "aclpci_dma_test_kernel.h"
#include "../aclpci_user_dma.c"
#include "../aclpci_dma_batch.c"
#include "../aclpci_dma_request.c"
#include "../aclpci_dma.c"
#include "../aclpci_fileio.c"

struct test_state test;
struct task_struct *current;
static struct mm_struct mm;
static struct task_struct submitter, worker_task;
static struct pci_dev pci;
static struct aclpci_dev device;
static struct aclpci_file file;
static u32 registers[128];
static u32 bar4[0x20000 / 4];
static char pio_buffer[PAGE_SIZE];
static struct cdev cdev;
static unsigned int map_calls;
struct map_record { dma_addr_t a; size_t n; enum dma_data_direction dir; bool live; };
static struct map_record maps[8192];
static unsigned int map_count;

void *test_alloc(size_t bytes)
{
    void *p;
    ++test.allocations;
    if (test.allocation_fail_at == test.allocations)
        return NULL;
    p = calloc(1, bytes ? bytes : 1);
    assert(p);
    ++test.live_allocs;
    return p;
}
void test_free(void *p)
{
    if (!p)
        return;
    assert(test.live_allocs);
    --test.live_allocs;
    ++test.frees;
    free(p);
}
int pin_user_pages_fast(unsigned long address, int n, unsigned int flags,
                        struct page **pages)
{
    int i, got = test.pin_result == INT_MAX ? n : test.pin_result;
    (void)address;
    assert(current == &submitter && current->mm == &mm);
    assert(mm.locked >= (unsigned int)n);
    ++test.pin_calls;
    test.pin_flags = flags;
    if (got < 0)
        return got;
    if (got > n)
        got = n;
    for (i = 0; i < got; ++i) {
        pages[i] = malloc(sizeof(*pages[i]));
        assert(pages[i]);
        pages[i]->index = i;
    }
    test.pins += got;
    return got;
}
void unpin_user_pages_dirty_lock(struct page **pages, unsigned int n, bool dirty)
{
    unsigned int i;
    test.unpins += n;
    if (dirty)
        test.dirty += n;
    for (i = 0; i < n; ++i)
        free(pages[i]);
}
dma_addr_t dma_map_page(struct device *dev, struct page *page, size_t offset,
                       size_t n, enum dma_data_direction dir)
{
    dma_addr_t address;
    assert(dev == &pci.dev && dev->refs > 1);
    assert(n && n <= PAGE_SIZE && offset + n <= PAGE_SIZE);
    if (++map_calls == test.map_fail_at)
        return UINT64_MAX;
    address = (test.zero_dma ? 0 : 0x10000000ULL) + 8192ULL * page->index + offset;
    if (map_calls == test.corrupt_map_at)
        address |= 2;
    assert(map_count < ARRAY_SIZE(maps));
    maps[map_count++] = (struct map_record){ address, n, dir, true };
    ++test.maps;
    return address;
}
void dma_unmap_page(struct device *dev, dma_addr_t address, size_t n,
                    enum dma_data_direction dir)
{
    unsigned int i;
    assert(dev == &pci.dev && dev->refs > 1);
    for (i = 0; i < map_count; ++i)
        if (maps[i].live && maps[i].a == address && maps[i].n == n && maps[i].dir == dir) {
            maps[i].live = false;
            ++test.unmaps;
            return;
        }
    assert(!"unmap mismatch or duplicate");
}
void *dma_alloc_coherent(struct device *dev, size_t n, dma_addr_t *address, int flags)
{
    void *p;
    (void)flags;
    assert(dev == &pci.dev);
    p = test_alloc(n);
    if (p) {
        *address = 0x80000000ULL + 65536ULL * test.coherent_allocs++;
        ++test.coherent_live;
    }
    return p;
}
void dma_free_coherent(struct device *dev, size_t n, void *p, dma_addr_t address)
{
    (void)n;
    (void)address;
    assert(dev == &pci.dev && p && test.coherent_live);
    --test.coherent_live;
    ++test.coherent_frees;
    test_free(p);
}
struct workqueue_struct *alloc_ordered_workqueue(const char *name, unsigned int flags)
{
    struct workqueue_struct *q;
    (void)name;
    (void)flags;
    if (test.fail_wq)
        return NULL;
    q = test_alloc(sizeof(*q));
    if (q)
        ++test.wq_allocs;
    return q;
}
struct workqueue_struct *create_singlethread_workqueue(const char *name)
{
    return alloc_ordered_workqueue(name, 0);
}
bool queue_work(struct workqueue_struct *q, struct work_struct *w)
{
    assert(q && w && w->fn);
    ++test.queues;
    q->work = w;
    if (w->queued)
        return false;
    w->queued = true;
    return true;
}
void flush_workqueue(struct workqueue_struct *q)
{
    struct task_struct *saved = current;
    unsigned int iterations = 0;
    assert(q);
    ++test.flushes;
    current = &worker_task;
    while (q->work && q->work->queued) {
        struct work_struct *w = q->work;
        assert(++iterations < 1000); /* test failure guard, not driver policy */
        assert(!w->running);
        w->queued = false;
        w->running = true;
        w->fn(w);
        w->running = false;
    }
    current = saved;
}
void destroy_workqueue(struct workqueue_struct *q)
{
    assert(q && (!q->work || (!q->work->queued && !q->work->running)));
    ++test.wq_frees;
    test_free(q);
}
void iowrite32(u32 value, void *p)
{
    uintptr_t offset = (uintptr_t)p - (uintptr_t)registers;
    uintptr_t bar4_offset = (uintptr_t)p - (uintptr_t)bar4;
    assert((offset < sizeof(registers) || bar4_offset < sizeof(bar4)) && !((uintptr_t)p & 3));
    ++test.mmio_writes;
    *(u32 *)p = value;
    if (offset == ACL_PCIE_DMA_RD_LAST_PTR || offset == ACL_PCIE_DMA_WR_LAST_PTR) {
        assert(test.wmbs > test.doorbells);
        ++test.doorbells;
        if (test.doorbell_hook)
            test.doorbell_hook();
    }
}
int send_sig_info(int signo, const struct kernel_siginfo *info,
                   struct task_struct *task)
{
    assert(signo == SIG_INT_NOTIFY && task && task->refs > 1);
    ++test.signal_count;
    test.signal = *info;
    test.signal_task = task;
    return test.signal_errors ? -ESRCH : 0;
}
void aclpci_get(struct aclpci_dev *d) { assert(d == &device); ++test.device_refs; }
void aclpci_put(struct aclpci_dev *d) { assert(d == &device && test.device_refs > 1); --test.device_refs; }
struct aclpci_dev *aclpci_get_by_minor(unsigned int minor, struct cdev *expected)
{
    if (minor || expected != device.cdev || device.removed)
        return NULL;
    aclpci_get(&device);
    return &device;
}
void aclpci_set_signal_task(struct aclpci_dev *d, struct task_struct *task)
{
    struct task_struct *old = d->user_task;
    if (task)
        get_task_struct(task);
    d->user_task = task;
    if (old)
        put_task_struct(old);
}
void mask_kernel_irq(struct aclpci_dev *d) { assert(d == &device); ++test.mask_calls; }
ssize_t aclpci_exec_cmd(struct aclpci_dev *d, struct acl_cmd command, size_t count)
{
    (void)count;
    assert(d == &device);
    ++test.command_calls;
    if (command.command == ACLPCI_CMD_SET_SIGNAL_PAYLOAD)
        d->signal_info_dma.si_int = *(int *)command.user_addr;
    return 0;
}

static void reset_fixture(void)
{
    assert(!test.live_allocs);
    assert(test.pins == test.unpins && test.maps == test.unmaps);
    memset(&test, 0, sizeof(test));
    memset(&device, 0, sizeof(device));
    memset(&file, 0, sizeof(file));
    memset(registers, 0, sizeof(registers));
    memset(bar4, 0, sizeof(bar4));
    memset(maps, 0, sizeof(maps));
    map_count = map_calls = 0;
    test.pin_result = INT_MAX;
    test.max_map = SIZE_MAX;
    pci.dev.refs = 1;
    mm = (struct mm_struct){ .refs = 1 };
    submitter = (struct task_struct){ .mm = &mm, .refs = 1 };
    worker_task = (struct task_struct){ .mm = NULL, .refs = 1 };
    current = &submitter;
    device.pci_dev = &pci;
    device.online = true;
    device.cdev = &cdev;
    device.buffer = pio_buffer;
    device.bar[4] = bar4;
    device.bar_length[4] = sizeof(bar4);
    test.device_refs = 1;
    device.bar[0] = registers;
    device.bar_length[0] = sizeof(registers);
    file.aclpci = &device;
    kref_init(&file.ref);
    device.signal_info_dma.si_signo = SIG_INT_NOTIFY;
    device.signal_info_dma.si_int = 0x5a;
    registers[ACL_PCIE_DMA_RD_LAST_PTR / 4] = ACL_PCIE_DMA_RESET_ID;
    registers[ACL_PCIE_DMA_WR_LAST_PTR / 4] = ACL_PCIE_DMA_RESET_ID;
    test.dev = &device;
}
static void released_mapping(void)
{
    assert(test.maps == test.unmaps && test.pins == test.unpins);
    assert(!mm.locked && mm.refs == 1 && pci.dev.refs == 1);
    assert(submitter.refs == 1 && file.ref.refs == 1);
}
static void test_mapping_faults(void)
{
    struct aclpci_user_dma *m;
    unsigned int i;
    for (i = 1; i <= 3; ++i) {
        reset_fixture();
        test.allocation_fail_at = i;
        assert(aclpci_user_dma_prepare(&pci.dev, 0x100000, 8192, DMA_TO_DEVICE, &m) == -ENOMEM);
        assert(!m);
        released_mapping();
        assert(!test.live_allocs);
    }
    reset_fixture();
    test.account_error = -ENOMEM;
    assert(aclpci_user_dma_prepare(&pci.dev, 0x100000, 8192, DMA_FROM_DEVICE, &m) == -ENOMEM);
    assert(!m && !test.pin_calls);
    released_mapping();
    reset_fixture();
    test.pin_result = 1;
    assert(aclpci_user_dma_prepare(&pci.dev, 0x100000, 8192, DMA_FROM_DEVICE, &m) == -EFAULT);
    assert(!m && !test.maps && !test.dirty);
    released_mapping();
    reset_fixture();
    test.map_fail_at = 2;
    assert(aclpci_user_dma_prepare(&pci.dev, 0x100000, 12288, DMA_FROM_DEVICE, &m) == -EIO);
    assert(!m && test.maps == 1 && !test.dirty);
    released_mapping();
    reset_fixture();
    test.max_map = 1024;
    assert(aclpci_user_dma_prepare(&pci.dev, 0x100000, 4096, DMA_TO_DEVICE, &m) == -E2BIG);
    released_mapping();
    reset_fixture();
    test.zero_dma = true;
    assert(!aclpci_user_dma_prepare(&pci.dev, 0x100000, 4096, DMA_TO_DEVICE, &m));
    assert(!(test.pin_flags & FOLL_WRITE));
    aclpci_user_dma_release(m, true);
    assert(!test.dirty);
    released_mapping();
    reset_fixture();
    assert(aclpci_user_dma_prepare(&pci.dev, ULONG_MAX - 3, 8, DMA_TO_DEVICE, &m) == -EOVERFLOW);
    assert(aclpci_user_dma_prepare(&pci.dev, 0, ((size_t)INT_MAX + 1) * PAGE_SIZE, DMA_TO_DEVICE, &m) == -EOVERFLOW);
    assert(aclpci_user_dma_prepare(&pci.dev, 0, 0, DMA_TO_DEVICE, &m) == -EINVAL);
    assert(!test.pin_calls && !test.live_allocs);
    puts("PASS mapping: allocation/memlock/partial pin/map/max-map unwind, zero DMA, direction dirty policy, range overflow");
}
static void test_offsets_and_owner(void)
{
    unsigned int offset;
    for (offset = 0; offset < 4096; offset += 4) {
        struct aclpci_user_dma *m;
        struct aclpci_dma_request r;
        struct aclpci_batch_descriptor descriptors[128];
        u64 ticket = 0, bytes = 0;
        unsigned int i;
        reset_fixture();
        assert(!aclpci_user_dma_prepare(&pci.dev, 0x100000 + offset, 8192, DMA_FROM_DEVICE, &m));
        assert(aclpci_dma_request_init(&r, m, 0x1000, 0, false) == -EINVAL);
        assert(!aclpci_dma_request_init(&r, m, 0x1000, 0, true));
        while (r.phase != ACLPCI_REQUEST_TERMINAL) {
            assert(!aclpci_dma_request_build(&r, descriptors));
            for (i = 0; i < r.count; ++i) {
                u64 dst = (u64)le32_to_cpu(descriptors[i].words[2]) |
                          ((u64)le32_to_cpu(descriptors[i].words[3]) << 32);
                unsigned int n = (le32_to_cpu(descriptors[i].words[4]) & ((1u << 18) - 1)) * 4;
                assert(n >= 4 && n <= 4096 && !(n & (n - 1)));
                assert((dst & 4095) + n <= 4096);
                bytes += n;
            }
            assert(!aclpci_dma_request_submit(&r, &ticket));
            assert(aclpci_dma_request_release(&r) == -EBUSY);
            assert(aclpci_dma_request_retire(&r, ticket + 1) == -ESTALE);
            assert(!aclpci_dma_request_retire(&r, ticket));
        }
        assert(bytes == 8192);
        assert(!aclpci_dma_request_release(&r));
        assert(test.dirty == test.pins);
        released_mapping();
    }
    puts("PASS descriptors/owner: all 1024 aligned page offsets, direction rejection, stale ticket, retained mapping");
}

/* Driver-path tests below execute aclpci_dma.c, including its worker. */
static void init_engine(void)
{
    reset_fixture();
    assert(!aclpci_dma_init(&device));
    assert(!device.dma_data.contract_valid);
    assert(test.coherent_live == 2);
    assert(aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                         4096, 1) == -EOPNOTSUPP);
    assert(!test.pin_calls && !test.doorbells);
    /* Mock-shell fixture only. Production has no switch to do this. */
    device.dma_data.contract_valid = true;
    device.dma_data.device_memory_bytes = 1ULL << 31;
}
static void finish_engine(void)
{
    assert(!aclpci_dma_finish(&device));
    released_mapping();
    assert(!test.live_allocs && !test.coherent_live);
    assert(test.coherent_allocs == test.coherent_frees);
    assert(test.wq_allocs == test.wq_frees);
}
static void run_work(void)
{
    flush_workqueue(device.dma_data.wq);
}
static void write_completion(u32 status)
{
    struct aclpci_dma *d = &device.dma_data;
    unsigned int direction = d->request.device_to_host;
    unsigned int index = d->request.first_id + d->request.count - 1;
    assert(d->active && index < 128);
    d->tables[direction]->header.flags[index] = cpu_to_le32(status);
}
static void complete_with_irq(void)
{
    write_completion(1);
    assert(aclpci_dma_service_interrupt(&device) == IRQ_HANDLED);
    run_work();
}
static void test_engine_init_and_sync_errors(void)
{
    unsigned int fail;
    for (fail = 1; fail <= 3; ++fail) {
        reset_fixture();
        test.allocation_fail_at = fail;
        assert(aclpci_dma_init(&device) == -ENOMEM);
        assert(!test.live_allocs && !test.coherent_live);
        assert(!device.dma_data.initialized);
        assert(!aclpci_dma_finish(&device));
    }
    reset_fixture();
    test.fail_wq = true;
    assert(aclpci_dma_init(&device) == -ENOMEM);
    assert(!test.live_allocs);
    init_engine();
    registers[ACL_PCIE_DMA_WR_LAST_PTR / 4] = 128;
    assert(aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                         4096, 1) == -EIO);
    registers[ACL_PCIE_DMA_WR_LAST_PTR / 4] = UINT32_MAX;
    assert(aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                         4096, 1) == -EIO);
    assert(!test.pin_calls && !test.doorbells);
    registers[ACL_PCIE_DMA_WR_LAST_PTR / 4] = ACL_PCIE_DMA_RESET_ID;
    test.map_fail_at = 2;
    assert(aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                         8192, 1) == -EIO);
    assert(!test.doorbells && !test.signal_count);
    released_mapping();
    /* A bad mapped address beyond the first 128 descriptors must fail
     * preflight synchronously before even the first table is published. */
    test.map_fail_at = 0;
    test.corrupt_map_at = map_calls + 130;
    assert(aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                         132 * PAGE_SIZE, 1) == -EINVAL);
    assert(!test.doorbells && !test.signal_count);
    released_mapping();
    assert(aclpci_dma_rw(&device, &file, (void *)(uintptr_t)(UINT64_MAX - 3),
                         (void *)0x100000, 8, 1) == -EOVERFLOW);
    assert(aclpci_dma_rw(&device, &file, (void *)0x200002, (void *)0x100000,
                         4096, 1) == -EINVAL);
    device.online = false;
    assert(aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                         4096, 1) == -ENODEV);
    finish_engine();
    puts("PASS integration: queue/coherent init unwind, default contract block, synchronous invalid pointer/map/range/offline errors");
}
static void test_engine_aperture(void)
{
    const u64 capacity = 1ULL << 31;
    const u64 addresses[] = {capacity, capacity - 4, capacity + 4,
                            1ULL << 32, capacity - 128 * PAGE_SIZE};
    const ssize_t lengths[] = {4, 8, 4, 4, 129 * PAGE_SIZE};
    unsigned int direction, i;
    for (direction = 0; direction < 2; ++direction) {
        init_engine();
        device.dma_data.device_memory_bytes = 0;
        assert(aclpci_dma_rw(&device, &file, (void *)0, (void *)0x100000,
                            4, direction) == -ERANGE);
        device.dma_data.device_memory_bytes = capacity;
        for (i = 0; i < sizeof(addresses) / sizeof(addresses[0]); ++i) {
            assert(aclpci_dma_rw(&device, &file,
                                (void *)(uintptr_t)addresses[i],
                                (void *)0x100000, lengths[i], direction) == -ERANGE);
        }
        assert(!test.pin_calls && !test.mmio_reads && !test.mmio_writes &&
               !test.doorbells && !device.dma_data.active);
        /* A request ending exactly at the aperture boundary is legal.
         * Exercise real descriptor publication and normal retirement. */
        assert(!aclpci_dma_rw(&device, &file,
                             (void *)(uintptr_t)(capacity - PAGE_SIZE),
                             (void *)0x100000, PAGE_SIZE, direction));
        assert(device.dma_data.active && test.pin_calls == 1);
        complete_with_irq();
        assert(!device.dma_data.active && !device.dma_data.async_result);
        finish_engine();
    }
    puts("PASS aperture: both directions, unknown/high/crossing/multibatch rejected before MMIO or pinning; exact-end retires");
}
static void test_pio_aperture(void)
{
    struct inode inode = { .i_cdev = &cdev, .minor = 0 };
    struct file fd = { 0 };
    u64 capacity = 1ULL << 31, segment;
    u32 value = 0xabcdef01;
    struct acl_cmd command = { .bar_id = ACLPCI_DMA_BAR, .size = 4,
                              .user_addr = &value };
    unsigned int direction, writes;
    init_engine();
    assert(!aclpci_open(&inode, &fd));
    for (direction = 0; direction < 2; ++direction) {
        const u64 bad[] = {capacity, capacity + 4, 1ULL << 32, UINT64_MAX - 3};
        unsigned int i;
        writes = test.mmio_writes;
        for (i = 0; i < ARRAY_SIZE(bad); ++i) {
            command.device_addr = (void *)(uintptr_t)bad[i];
            assert(aclpci_rw(&fd, (char *)&command, sizeof(command), NULL,
                             direction) == -ERANGE);
        }
        device.dma_data.device_memory_bytes = 0;
        command.device_addr = 0;
        assert(aclpci_rw(&fd, (char *)&command, sizeof(command), NULL,
                         direction) == -ERANGE);
        device.dma_data.device_memory_bytes = capacity;
        assert(test.mmio_writes == writes && !test.pin_calls);
    }
    command.bar_id = ACL_PCIE_MEMWINDOW_BAR;
    command.device_addr = (void *)ACL_PCIE_MEMWINDOW_CRA;
    command.size = 8;
    command.user_addr = &segment;
    writes = test.mmio_writes;
    segment = capacity;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -ERANGE);
    segment = 1;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -ERANGE);
    assert(test.mmio_writes == writes);
    segment = capacity - ACL_PCIE_MEMWINDOW_SIZE;
    assert(!aclpci_write(&fd, (char *)&command, sizeof(command), NULL));
    command.device_addr = (void *)(ACL_PCIE_MEMWINDOW_BASE + ACL_PCIE_MEMWINDOW_SIZE - 4);
    command.size = 4;
    command.user_addr = &value;
    assert(!aclpci_write(&fd, (char *)&command, sizeof(command), NULL));
    /* An image can expose only part of its final window. Raw BAR access must
     * not bypass that bound even with a valid aligned segment register. */
    device.dma_data.device_memory_bytes = capacity - 4;
    writes = test.mmio_writes;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -ERANGE);
    assert(aclpci_read(&fd, (char *)&command, sizeof(command), NULL) == -ERANGE);
    assert(test.mmio_writes == writes);
    device.dma_data.device_memory_bytes = capacity;
    /* An untrusted retained hardware segment is checked before data access. */
    *(u64 *)((char *)bar4 + ACL_PCIE_MEMWINDOW_CRA) = UINT64_MAX - 65535;
    device.global_mem_segment_valid = false;
    assert(aclpci_read(&fd, (char *)&command, sizeof(command), NULL) == -ERANGE);
    assert(!aclpci_close(&inode, &fd));
    finish_engine();
    puts("PASS PIO aperture: global and raw-window paths, segment alignment/range, exact-end and partial final window");
}
static void test_engine_multitable(void)
{
    struct aclpci_dma *d;
    unsigned int i, initial_pins;
    init_engine();
    d = &device.dma_data;
    /* Begin part way through the historical 128-entry ID ring. */
    registers[ACL_PCIE_DMA_WR_LAST_PTR / 4] = 126;
    assert(!aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                          260 * PAGE_SIZE, 1));
    initial_pins = test.pins;
    assert(initial_pins == 260 && test.pin_calls == 1);
    assert(d->request.first_id == 127 && d->request.count == 1);
    assert(test.doorbells == 1 && file.ref.refs == 2 && submitter.refs == 2);
    assert(mm.refs == 2 && mm.locked == 260);
    assert(aclpci_dma_rw(&device, &file, (void *)0x300000, (void *)0x200000,
                         4096, 0) == -EBUSY);
    /* Wrong direction and wrong index cannot qualify this table. */
    d->tables[0]->header.flags[127] = cpu_to_le32(1);
    d->tables[1]->header.flags[126] = cpu_to_le32(1);
    for (i = 0; i < 4; ++i)
        aclpci_dma_service_interrupt(&device);
    run_work();
    assert(test.doorbells == 1 && test.rmbs == 0 && !test.unmaps);
    device.signal_info_dma.si_int = 0x77;
    for (i = 0; i < 4; ++i) {
        unsigned int before = test.doorbells;
        write_completion(1);
        aclpci_dma_service_interrupt(&device);
        aclpci_dma_service_interrupt(&device); /* coalesced duplicate IRQ */
        run_work();
        if (i < 3) {
            assert(d->active && test.doorbells == before + 1);
            assert(!test.unmaps && !test.unpins && !test.signal_count);
            assert(test.pins == initial_pins && test.pin_calls == 1);
            /* Queued stale IRQ rescans the newly cleared current status. */
            aclpci_dma_service_interrupt(&device);
            run_work();
            assert(test.doorbells == before + 1 && !test.signal_count);
        }
    }
    assert(!d->active && test.doorbells == 4 && test.rmbs == 4);
    assert(test.signal_count == 1 && test.signal.si_int == 0x5a && !test.signal.si_errno);
    assert(test.signal_task == &submitter && test.dirty == 260);
    assert(aclpci_dma_get_idle_status(&device) == 1);
    aclpci_dma_service_interrupt(&device);
    run_work();
    assert(test.signal_count == 1);
    released_mapping();
    /* A stale callback carries no old request pointer into a new H2D request. */
    aclpci_dma_service_interrupt(&device);
    assert(!aclpci_dma_rw(&device, &file, (void *)0x300000, (void *)0x100000,
                          4096, 0));
    run_work();
    assert(d->active && test.signal_count == 1);
    complete_with_irq();
    assert(test.signal_count == 2 && test.dirty == 260);
    finish_engine();
    puts("PASS integration: 260-page/four-table ring, one caller-mm pin owner, exact direction/index, duplicate/stale IRQ, one captured completion");
}
static void irq_during_doorbell(void)
{
    write_completion(1);
    aclpci_dma_service_interrupt(&device);
}
static void test_engine_running_worker_irq(void)
{
    init_engine();
    assert(!aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                          256 * PAGE_SIZE, 0));
    test.doorbell_hook = irq_during_doorbell;
    complete_with_irq();
    /* The next table completed while the same work callback was executing.
     * queue_work requeued it, so no later external interrupt is needed. */
    assert(!device.dma_data.active && test.doorbells == 2 && test.signal_count == 1);
    assert(test.pin_calls == 1 && test.rmbs == 2);
    test.doorbell_hook = NULL;
    finish_engine();
    init_engine();
    test.signal_errors = 1;
    assert(!aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                          4096, 0));
    complete_with_irq();
    aclpci_dma_service_interrupt(&device);
    run_work();
    assert(test.signal_count == 1 && aclpci_dma_get_idle_status(&device) == 1);
    finish_engine();
    puts("PASS integration: running-worker IRQ requeues without a lost event; failed signal delivery leaves queryable completion without duplicate attempt");
}
static void test_engine_stop_retention(void)
{
    struct aclpci_dma *d;
    unsigned int coherent;
    init_engine();
    d = &device.dma_data;
    assert(!aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                          256 * PAGE_SIZE, 1));
    coherent = test.coherent_live;
    file.closed = true; /* Last close drops its independent ref after stop. */
    assert(aclpci_dma_stop(&device) == -EINPROGRESS);
    assert(d->request.stop && d->active && !test.unmaps && file.ref.refs == 2);
    assert(test.signal_count == 0);
    device.online = false; /* remove/offline prevents any new table */
    assert(aclpci_dma_finish(&device) == -EBUSY);
    assert(test.coherent_live == coherent && d->initialized && d->wq);
    assert(mm.locked == 256 && mm.refs == 2 && pci.dev.refs == 2);
    assert(aclpci_dma_rw(&device, &file, (void *)0x300000, (void *)0x100000,
                         4096, 1) == -ENODEV);
    /* Only hardware-qualified completion may now release the retained owner. */
    complete_with_irq();
    assert(!d->active && test.doorbells == 1 && test.signal_count == 1);
    assert(test.signal.si_errno == ECANCELED && test.dirty == 256);
    assert(aclpci_dma_get_idle_status(&device) == -ECANCELED);
    assert(!aclpci_dma_stop(&device));
    assert(test.signal_count == 1);
    finish_engine();
    /* Status already written but interrupt not yet serviced: stop harvests it
     * once. A previously queued worker cannot duplicate the notification. */
    init_engine();
    assert(!aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                          4096, 0));
    write_completion(1);
    aclpci_dma_service_interrupt(&device);
    assert(!aclpci_dma_stop(&device));
    run_work();
    assert(test.signal_count == 1 && test.signal.si_errno == ECANCELED);
    finish_engine();
    puts("PASS integration: stop/closed-file/offline/finish retain unretired owner+tables; qualified cancel release and pending-worker deduplication");
}
/* Tests inspect permanent quarantine, then reclaim their isolated fake
 * hardware fixture. This helper is NOT a driver recovery operation: no
 * corresponding production API can clear fault/contract_valid. */
static void destroy_quarantined_mock(void)
{
    struct aclpci_dma *d = &device.dma_data;
    assert(d->active && d->fault && !d->contract_valid);
    assert(aclpci_dma_finish(&device) == -EBUSY);
    assert(!test.unmaps && !test.signal_count && test.coherent_live == 2);
    /* Stop the mock device permanently before freeing its fake allocations.
     * Deliberately bypass the driver; this is just test-process teardown. */
    aclpci_user_dma_release(d->request.mapping, d->request.may_have_written);
    d->request.mapping = NULL;
    put_task_struct(d->task);
    aclpci_file_put(d->owner);
    d->task = NULL;
    d->owner = NULL;
    d->active = false;
    finish_engine();
}
static void test_engine_bad_status_and_bounds(void)
{
    struct aclpci_dma *d;
    unsigned int saved;
    init_engine();
    d = &device.dma_data;
    assert(!aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                          4096, 1));
    write_completion(2);
    aclpci_dma_service_interrupt(&device);
    run_work();
    assert(d->active && d->fault == -EIO && !d->contract_valid && !test.rmbs && !test.unmaps);
    assert(aclpci_dma_get_idle_status(&device) == -EIO);
    write_completion(1); /* Later overwrite cannot repair invalid evidence. */
    aclpci_dma_service_interrupt(&device);
    run_work();
    assert(d->active && !test.rmbs && !test.unmaps && !test.signal_count);
    destroy_quarantined_mock();
    init_engine();
    d = &device.dma_data;
    assert(!aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                          4096, 1));
    saved = d->request.first_id;
    d->request.first_id = UINT_MAX; /* injected corrupted bookkeeping */
    aclpci_dma_service_interrupt(&device);
    run_work();
    assert(d->active && !test.rmbs && !test.unmaps && d->fault == -EIO);
    d->request.first_id = saved;
    destroy_quarantined_mock();
    init_engine();
    d = &device.dma_data;
    assert(!aclpci_dma_rw(&device, &file, (void *)0x200000, (void *)0x100000,
                          4096, 1));
    d->last_id[1] = -1;
    aclpci_dma_service_interrupt(&device);
    run_work();
    assert(d->active && !test.rmbs && !test.unmaps && d->fault == -EIO);
    destroy_quarantined_mock();
    puts("PASS integration: non-one status and invalid unsigned/negative status-index bookkeeping permanently quarantine, even after later status one");
}

static void test_file_open_close_and_pending_owner(void)
{
    struct inode inode = { .i_cdev = &cdev, .minor = 0 };
    struct cdev stale = { 0 };
    struct file first = { 0 }, second = { 0 };
    struct aclpci_file *owner;
    struct acl_cmd command = { .bar_id = ACLPCI_DMA_BAR, .size = 8192,
        .device_addr = (void *)0x200000, .user_addr = (void *)0x100000 };
    unsigned int before;

    init_engine();
    device.irq_registered = true;
    inode.i_cdev = &stale;
    assert(aclpci_open(&inode, &first) == -ENODEV);
    inode.i_cdev = &cdev;
    test.allocation_fail_at = test.allocations + 1;
    assert(aclpci_open(&inode, &first) == -ENOMEM);
    test.allocation_fail_at = 0;
    test.fail_module = true;
    assert(aclpci_open(&inode, &first) == -ENODEV);
    test.fail_module = false;
    test.fail_down = true;
    assert(aclpci_open(&inode, &first) == -ERESTARTSYS);
    test.fail_down = false;
    device.online = false;
    assert(aclpci_open(&inode, &first) == -ENODEV);
    device.online = true;
    device.bar_length[4] = 0;
    assert(aclpci_open(&inode, &first) == -ENODEV);
    device.bar_length[4] = sizeof(bar4);
    device.num_handles_open = INT_MAX;
    assert(aclpci_open(&inode, &first) == -EOVERFLOW);
    device.num_handles_open = 0;
    assert(test.device_refs == 1 && !test.module_refs && !first.private_data);
    assert(!aclpci_open(&inode, &first));
    assert(!aclpci_open(&inode, &second));
    assert(device.num_handles_open == 2 && test.device_refs == 3 && test.module_refs == 2);
    assert(submitter.refs == 2);
    before = test.flushes;
    assert(!aclpci_close(&inode, &first));
    assert(device.num_handles_open == 1 && !test.mask_calls && submitter.refs == 2);
    assert(!aclpci_close(&inode, &second));
    assert(!device.num_handles_open && test.device_refs == 1 && !test.module_refs);
    assert(test.mask_calls == 1 && test.flushes == before && submitter.refs == 1);
    assert(!aclpci_open(&inode, &first));
    owner = first.private_data;
    assert(!aclpci_read(&first, (char *)&command, sizeof(command), NULL));
    assert(device.dma_data.owner == owner && owner->ref.refs == 2);
    assert(mm.locked == 2 && submitter.refs == 3);
    before = test.flushes;
    test.fail_down = true; /* close uses uninterruptible down(), not interrupted exit */
    assert(!aclpci_close(&inode, &first));
    test.fail_down = false;
    assert(!first.private_data && owner->closed && owner->ref.refs == 1);
    assert(test.flushes == before && device.dma_data.active && device.dma_data.request.stop);
    assert(test.module_refs == 1 && test.device_refs == 2 && submitter.refs == 2);
    complete_with_irq();
    assert(!device.dma_data.active && test.signal.si_errno == ECANCELED);
    assert(test.device_refs == 1 && !test.module_refs && submitter.refs == 1);
    finish_engine();
    puts("PASS fileio: real open unwind/multiple closes; real last close retains request context and module/device/task refs without flushing its worker");
}
static void test_file_after_unbind_and_protected_io(void)
{
    struct inode inode = { .i_cdev = &cdev, .minor = 0 };
    struct file fd = { 0 };
    struct acl_cmd command = { .bar_id = 4, .size = 4,
        .device_addr = (void *)0x4000 };
    const unsigned long protected_offsets[] = {
        PCIE_CRA_IRQ_ENABLE, PCIE_CRA_IRQ_STATUS,
        ACL_PRCONTROLLER_OFFSET, ACL_UNIPHYRESET_OFFSET
    };
    u32 value = 0x12345678, output = 0;
    u64 segment = 0x20000;
    unsigned int i, before;
    ssize_t error;

    init_engine();
    device.irq_registered = true;
    assert(!aclpci_open(&inode, &fd));
    command.user_addr = &value;
    device.dma_data.contract_valid = false;
    before = test.mmio_writes;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -EOPNOTSUPP);
    assert(test.mmio_writes == before);
    device.dma_data.contract_valid = true;
    assert(!aclpci_write(&fd, (char *)&command, sizeof(command), NULL));
    assert(bar4[0x4000 / 4] == value);
    command.user_addr = &output;
    assert(!aclpci_read(&fd, (char *)&command, sizeof(command), NULL));
    assert(output == value);
    before = test.mmio_writes;
    command.user_addr = NULL;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -EFAULT);
    assert(test.mmio_writes == before && bar4[0x4000 / 4] == value);
    command.user_addr = &value;
    for (i = 0; i < ARRAY_SIZE(protected_offsets); ++i) {
        command.device_addr = (void *)protected_offsets[i];
        assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -EPERM);
        command.device_addr = (void *)(protected_offsets[i] - 1);
        command.size = 2;
        assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -EPERM);
        command.size = 4;
    }
    command.bar_id = 0;
    command.device_addr = (void *)ACL_PCIE_DMA_RD_LAST_PTR;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -EPERM);
    command.device_addr = (void *)ACL_PCIE_DMA_WR_LAST_PTR;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -EPERM);
    assert(test.mmio_writes == before);
    assert(!aclpci_get_checked_addr(-1, 0, 1, &device, &error, 0) && error == -EFAULT);
    assert(!aclpci_get_checked_addr(5, 0, 1, &device, &error, 0) && error == -EFAULT);
    assert(!aclpci_get_checked_addr(4, (void *)sizeof(bar4), 1, &device, &error, 0) && error == -EFAULT);
    assert(!aclpci_get_checked_addr(4, (void *)ULONG_MAX, 8, &device, &error, 0) && error == -EFAULT);
    command.bar_id = 4;
    command.device_addr = (void *)0x4000;
    command.size = SIZE_MAX;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -EOVERFLOW);
    command.size = 4;
    command.device_addr = (void *)ACL_PCIE_MEMWINDOW_CRA;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -EINVAL);
    command.size = 8;
    command.user_addr = &segment;
    assert(!aclpci_write(&fd, (char *)&command, sizeof(command), NULL));
    assert(*(u64 *)((char *)bar4 + ACL_PCIE_MEMWINDOW_CRA) == segment);
    /* PIO global-memory path snapshots and restores the actual segment. */
    *(u64 *)((char *)bar4 + ACL_PCIE_MEMWINDOW_CRA) = 0x30000;
    device.global_mem_segment_valid = false;
    bar4[(ACL_PCIE_MEMWINDOW_BASE + 4) / 4] = value;
    command.bar_id = ACLPCI_DMA_BAR;
    command.size = 4;
    command.device_addr = (void *)0x10004;
    command.user_addr = &output;
    assert(!aclpci_read(&fd, (char *)&command, sizeof(command), NULL));
    assert(output == value && *(u64 *)((char *)bar4 + ACL_PCIE_MEMWINDOW_CRA) == 0x30000);
    command.user_addr = NULL;
    assert(aclpci_write(&fd, (char *)&command, sizeof(command), NULL) == -EFAULT);
    assert(*(u64 *)((char *)bar4 + ACL_PCIE_MEMWINDOW_CRA) == 0x30000);
    command.size = 8;
    command.device_addr = (void *)0xfffc;
    assert(aclpci_read(&fd, (char *)&command, sizeof(command), NULL) == -ERANGE);
    command.bar_id = ACLPCI_CMD_BAR;
    command.command = ACLPCI_CMD_SET_SIGNAL_PAYLOAD;
    command.user_addr = &value;
    assert(!aclpci_write(&fd, (char *)&command, sizeof(command), NULL));
    assert(test.irq_disables == 1 && test.irq_enables == 1 && test.command_calls == 1);
    /* The open context survives unbind; read/write must reject before any
     * BAR or user pointer access. This is actual fileio, with lifetime/PCI
     * removal supplied by a fixture; actual remove is tested separately. */
    device.online = false;
    device.removed = true;
    device.bar[0] = device.bar[4] = NULL;
    before = test.mmio_writes;
    assert(aclpci_read(&fd, (char *)1, sizeof(command), NULL) == -ENODEV);
    assert(aclpci_write(&fd, (char *)1, sizeof(command), NULL) == -ENODEV);
    assert(!aclpci_close(&inode, &fd));
    assert(test.mmio_writes == before && !test.module_refs && test.device_refs == 1);
    finish_engine();
    puts("PASS fileio: bounds/protected writes/default offline gate, copy faults, segment restoration, signal IRQ exclusion, open file after unbind");
}

int main(void)
{
    test_mapping_faults();
    test_offsets_and_owner();
    test_engine_init_and_sync_errors();
    test_engine_aperture();
    test_pio_aperture();
    test_engine_multitable();
    test_engine_running_worker_irq();
    test_engine_stop_retention();
    test_engine_bad_status_and_bounds();
    test_file_open_close_and_pending_owner();
    test_file_after_unbind_and_protected_io();
    puts("PASS all eleven executable suites (mock kernel/MMIO; not a native kernel or hardware qualification)");
    return 0;
}
