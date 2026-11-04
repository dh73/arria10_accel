/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_DMA_TEST_KERNEL_H
#define ACLPCI_DMA_TEST_KERNEL_H
/* Mock kernel primitives only. integration.c includes the actual mapping,
 * descriptor, request and DMA-driver C files; there is no alternate engine. */
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <sys/types.h>
/* Do not include libc errno.h: glibc includes linux/errno.h recursively. */
typedef unsigned int __poll_t;
typedef struct { unsigned wakes, registrations; } wait_queue_head_t;
typedef struct { unsigned unused; } poll_table;
struct file;
#define EPOLLIN 1
#define EPOLLRDNORM 64
#define EPOLLERR 8
static inline void init_waitqueue_head(wait_queue_head_t *q) { q->wakes=0; q->registrations=0; }
static inline void wake_up_interruptible(wait_queue_head_t *q) { ++q->wakes; }
static inline void poll_wait(struct file *f,wait_queue_head_t *q,poll_table *p) { (void)f; if(p)++q->registrations; }
#define EPERM 1
#define ENOENT 2
#define ESRCH 3
#define EINTR 4
#define EIO 5
#define ENXIO 6
#define E2BIG 7
#define ENOMEM 12
#define EACCES 13
#define EFAULT 14
#define EBUSY 16
#define ENODEV 19
#define EINVAL 22
#define EOVERFLOW 75
#define ERANGE 34
#define EOPNOTSUPP 95
#define EINPROGRESS 115
#define ESTALE 116
#define ECANCELED 125
#define ESHUTDOWN 108
#define ERESTARTSYS 512
#define __user
#define __iomem
#define __packed __attribute__((packed))
#define GFP_KERNEL 0
#define WQ_MEM_RECLAIM 1
#define PAGE_SHIFT 12
#define PAGE_SIZE (1UL << PAGE_SHIFT)
#define PAGE_MASK (~(PAGE_SIZE - 1))
#define offset_in_page(x) ((x) & (PAGE_SIZE - 1))
#define FOLL_WRITE 1
#define FOLL_LONGTERM 2
#define USE_DMA 1
#define POLLING 0
#define SIG_INT_NOTIFY 44
#define IRQ_NONE 0
#define IRQ_HANDLED 1
#define BUILD_BUG_ON(x) _Static_assert(!(x), #x)
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define min_t(t, a, b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
#define check_add_overflow(a, b, p) __builtin_add_overflow((a), (b), (p))
#define cpu_to_le32(x) ((uint32_t)(x))
#define le32_to_cpu(x) ((uint32_t)(x))
#define le64_to_cpu(x) ((uint64_t)(x))
#define lower_32_bits(x) ((uint32_t)(x))
#define upper_32_bits(x) ((uint32_t)((uint64_t)(x) >> 32))
#define READ_ONCE(x) (*(volatile __typeof__(x) *)&(x))
#define WRITE_ONCE(x,v) ((x) = (v))
#define container_of(p,t,m) ((t *)((char *)(p) - offsetof(t,m)))
#define WARN_ON(x) (!!(x))
#define WARN_ON_ONCE(x) (!!(x))
#define ACL_DEBUG(...) ((void)0)
#define ACL_VERBOSE_DEBUG(...) ((void)0)
#define KERN_ERR ""
#define KERN_WARNING ""
#define KERN_DEBUG ""
#define dev_err(...) ((void)0)
#define dev_warn(...) ((void)0)
#define dev_err_ratelimited(...) ((void)0)
#define pr_err(...) ((void)0)
#define pr_warn(...) ((void)0)
#define printk(...) ((void)0)
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#include "../aclpci_startup.h"
#include "../aclpci_identity.h"
typedef uint32_t __le32;
typedef uint64_t __le64;
typedef uint64_t dma_addr_t;
typedef int irqreturn_t;
enum dma_data_direction { DMA_BIDIRECTIONAL, DMA_TO_DEVICE, DMA_FROM_DEVICE, DMA_NONE };
struct device { unsigned int refs; };
struct pci_dev { struct device dev; };
struct mm_struct { unsigned int refs; unsigned long locked; };
struct task_struct { struct mm_struct *mm; unsigned int refs; };
struct page { unsigned int index; };
struct kernel_siginfo { int si_signo, si_code, si_errno, si_int; };
struct mutex { bool held; };
struct work_struct { void (*fn)(struct work_struct *); bool queued, running; };
struct workqueue_struct { struct work_struct *work; };
typedef struct { int counter; } atomic_t;
static inline void atomic_set(atomic_t *a, int v) { a->counter = v; }
static inline int atomic_read(const atomic_t *a) { return a->counter; }
static inline int atomic_xchg(atomic_t *a, int v) { int old=a->counter; a->counter=v; return old; }
struct kref { unsigned int refs; };
struct semaphore { bool held; };
struct cdev { int identity; };
struct inode { struct cdev *i_cdev; unsigned int minor; };
struct file { void *private_data; };
#include "../pcie_linux_driver_exports.h"
#define iminor(i) ((i)->minor)
#define BUF_SIZE PAGE_SIZE
static inline void kref_init(struct kref *r) { r->refs=1; }
static inline void kref_get(struct kref *r) { assert(r->refs); ++r->refs; }
static inline void kref_put(struct kref *r, void (*release)(struct kref *)) { assert(r->refs); if (!--r->refs) release(r); }
struct aclpci_dev;
struct aclpci_file;
extern struct task_struct *current;
struct test_state {
    unsigned int allocations, frees, live_allocs, allocation_fail_at;
    unsigned int pins, unpins, pin_calls, pin_flags, dirty;
    int pin_result, account_error;
    unsigned int maps, unmaps, map_fail_at, corrupt_map_at;
    size_t max_map;
    bool zero_dma;
    unsigned int coherent_allocs, coherent_frees, coherent_live;
    unsigned int wq_allocs, wq_frees, queues;
    bool fail_wq, fail_module, fail_copy, fail_down;
    unsigned int device_refs, flushes, mask_calls, irq_disables, irq_enables, mmio_writes, mmio_reads, command_calls;
    unsigned int signal_count, signal_errors;
    struct kernel_siginfo signal;
    struct task_struct *signal_task;
    unsigned int wmbs, rmbs, doorbells;
    unsigned int module_refs;
    struct aclpci_dev *dev;
    void (*doorbell_hook)(void);
};
extern struct test_state test;
void *test_alloc(size_t bytes);
void test_free(void *ptr);
static inline void *kzalloc(size_t n, int flags) { (void)flags; return test_alloc(n); }
static inline void *kvmalloc_array(size_t n, size_t s, int flags) { (void)flags; if (s && n > SIZE_MAX/s) return NULL; return test_alloc(n*s); }
#define kfree test_free
#define kvfree test_free
static inline struct device *get_device(struct device *d) { assert(d); ++d->refs; return d; }
static inline void put_device(struct device *d) { assert(d && d->refs); --d->refs; }
static inline void mmget(struct mm_struct *m) { assert(m); ++m->refs; }
static inline void mmput(struct mm_struct *m) { assert(m && m->refs); --m->refs; }
static inline int account_locked_vm(struct mm_struct *m, unsigned long n, bool add) { if(add) { if(test.account_error) return test.account_error; m->locked+=n; } else { assert(m->locked>=n); m->locked-=n; } return 0; }
int pin_user_pages_fast(unsigned long a, int n, unsigned int flags, struct page **pages);
void unpin_user_pages_dirty_lock(struct page **pages, unsigned int n, bool dirty);
static inline size_t dma_max_mapping_size(struct device *d) { (void)d; return test.max_map; }
dma_addr_t dma_map_page(struct device *d, struct page *p, size_t offset, size_t n, enum dma_data_direction dir);
void dma_unmap_page(struct device *d, dma_addr_t a, size_t n, enum dma_data_direction dir);
static inline bool dma_mapping_error(struct device *d, dma_addr_t a) { (void)d; return a == UINT64_MAX; }
void *dma_alloc_coherent(struct device *d, size_t n, dma_addr_t *a, int flags);
void dma_free_coherent(struct device *d, size_t n, void *p, dma_addr_t a);
static inline void mutex_init(struct mutex *m) { m->held=false; }
static inline void mutex_lock(struct mutex *m) { assert(!m->held); m->held=true; }
static inline void mutex_unlock(struct mutex *m) { assert(m->held); m->held=false; }
#define lockdep_assert_held(m) assert((m)->held)
#define INIT_WORK(w, f) do { (w)->fn=(f); (w)->queued=false; (w)->running=false; } while(0)
struct workqueue_struct *alloc_ordered_workqueue(const char *name, unsigned int flags);
struct workqueue_struct *create_singlethread_workqueue(const char *name);
bool queue_work(struct workqueue_struct *q, struct work_struct *w);
void flush_workqueue(struct workqueue_struct *q);
void destroy_workqueue(struct workqueue_struct *q);
static inline void dma_wmb(void) { ++test.wmbs; }
static inline void dma_rmb(void) { ++test.rmbs; }
static inline void wmb(void) { ++test.wmbs; }
static inline u32 ioread32(const void *p) { ++test.mmio_reads; return *(const u32 *)p; }
static inline u32 readl(const void *p) { return ioread32(p); }
void iowrite32(u32 value, void *p);
static inline void writel(u32 value, void *p) { iowrite32(value, p); }
static inline void get_task_struct(struct task_struct *t) { assert(t); ++t->refs; }
static inline void put_task_struct(struct task_struct *t) { assert(t && t->refs); --t->refs; }
int send_sig_info(int sig, const struct kernel_siginfo *info, struct task_struct *task);
#define THIS_MODULE ((void *)1)
static inline bool try_module_get(void *p) { (void)p; if(test.fail_module) return false; ++test.module_refs; return true; }
static inline void __module_get(void *p) { (void)p; ++test.module_refs; }
static inline void module_put(void *p) { (void)p; assert(test.module_refs); --test.module_refs; }
/* These are the exact constants supplied in the source packet. */
#define ACL_PCIE_DMA_INTERNAL_BAR 0
#define ACL_PCIE_DMA_INTERNAL_CTR_BASE 0
#define ACL_PCIE_DMA_RC_RD_DESC_BASE_LOW 0x0000
#define ACL_PCIE_DMA_RC_RD_DESC_BASE_HIGH 0x0004
#define ACL_PCIE_DMA_EP_RD_FIFO_BASE_LOW 0x0008
#define ACL_PCIE_DMA_EP_RD_FIFO_BASE_HIGH 0x000c
#define ACL_PCIE_DMA_RD_LAST_PTR 0x0010
#define ACL_PCIE_DMA_RD_TABLE_SIZE 0x0014
#define ACL_PCIE_DMA_RD_CONTROL 0x0018
#define ACL_PCIE_DMA_RC_WR_DESC_BASE_LOW 0x0100
#define ACL_PCIE_DMA_RC_WR_DESC_BASE_HIGH 0x0104
#define ACL_PCIE_DMA_EP_WR_FIFO_BASE_LOW 0x0108
#define ACL_PCIE_DMA_EP_WR_FIFO_BASE_HIGH 0x010c
#define ACL_PCIE_DMA_WR_LAST_PTR 0x0110
#define ACL_PCIE_DMA_WR_TABLE_SIZE 0x0114
#define ACL_PCIE_DMA_WR_CONTROL 0x0118
#define ACL_PCIE_DMA_ONCHIP_RD_FIFO_BASE_LO 0xffff0000
#define ACL_PCIE_DMA_ONCHIP_RD_FIFO_BASE_HI 0x00007fff
#define ACL_PCIE_DMA_ONCHIP_WR_FIFO_BASE_LO 0xffff2000
#define ACL_PCIE_DMA_ONCHIP_WR_FIFO_BASE_HI 0x00007fff
#define ACL_PCIE_DMA_TABLE_SIZE 128
#define ACL_PCIE_DMA_RESET_ID 0xff
#define ACL_PCI_NUM_BARS 5
#define ACL_PCI_CRA_BAR 4
#define ACL_PCIE_MEMWINDOW_BAR 4
#define ACL_PCIE_MEMWINDOW_CRA 0x0c870
#define ACL_PCIE_MEMWINDOW_BASE 0x10000
#define ACL_PCIE_MEMWINDOW_SIZE 0x10000
#define PCIE_CRA_IRQ_STATUS 0xcf90
#define PCIE_CRA_IRQ_ENABLE 0xcfa0
#define ACL_PRCONTROLLER_BAR 4
#define ACL_PRCONTROLLER_OFFSET 0xcfb0
#define ACL_UNIPHYRESET_BAR 4
#define ACL_UNIPHYRESET_OFFSET 0xcfd0
#define DMA_ALIGNMENT_BYTE_MASK 63
#define ACLPCI_CMD_BAR 23
#define ACLPCI_CMD_DMA_STOP 19
#define ACLPCI_DMA_BAR 25
#define ACLPCI_CMD_SET_SIGNAL_PAYLOAD 12
#define ACLPCI_CMD_ENABLE_KERNEL_IRQ 14
static inline int down_interruptible(struct semaphore *s) { if(test.fail_down) return -EINTR; assert(!s->held); s->held=true; return 0; }
static inline void down(struct semaphore *s) { assert(!s->held); s->held=true; }
static inline void up(struct semaphore *s) { assert(s->held); s->held=false; }
static inline int copy_from_user(void *dst, const void *src, size_t n) { if(test.fail_copy || !src) return 1; memcpy(dst,src,n); return 0; }
static inline int copy_to_user(void *dst, const void *src, size_t n) { if(test.fail_copy || !dst) return 1; memcpy(dst,src,n); return 0; }
static inline u8 readb(const void *p) { return *(const u8 *)p; }
static inline u16 readw(const void *p) { return *(const u16 *)p; }
static inline u64 readq(const void *p) { return *(const u64 *)p; }
static inline void writeb(u8 v, void *p) { ++test.mmio_writes; *(u8 *)p=v; }
static inline void writew(u16 v, void *p) { ++test.mmio_writes; *(u16 *)p=v; }
static inline void writeq(u64 v, void *p) { ++test.mmio_writes; *(u64 *)p=v; }
#define __raw_readw readw
#define __raw_readl readl
#define __raw_writew writew
#define __raw_writel writel
#define mb() ((void)0)
static inline void disable_irq(int n) { (void)n; ++test.irq_disables; }
static inline void enable_irq(int n) { (void)n; ++test.irq_enables; }
#include "../aclpci_dma.h"
struct aclpci_dev {
    struct aclpci_file *control_owner;
    bool control_debt;
    struct aclpci_startup control_startup;
    struct pci_dev *pci_dev;
    struct aclpci_dma dma_data;
    void *bar[5];
    size_t bar_length[5];
    bool online, io_blocked, pr_in_progress, removed, irq_registered;
    int irq_number, num_handles_open;
    struct semaphore sem;
    struct cdev *cdev;
    struct task_struct *user_task;
    char *buffer;
    u64 global_mem_segment;
    bool global_mem_segment_valid;
    void *global_mem_segment_addr;
    struct kernel_siginfo signal_info_dma;
    atomic_t status;
};
struct aclpci_file {
    struct kref ref;
    struct aclpci_dev *aclpci;
    bool closed;
    /* Protected by dma_data.lock; completion published after mapping release. */
    u64 dma_submitted, dma_completed;
    int dma_completion_result;
    wait_queue_head_t dma_completion_wait;
    int async_error;
};
void aclpci_file_get(struct aclpci_file *f);
void aclpci_file_put(struct aclpci_file *f);
void aclpci_get(struct aclpci_dev *d);
void aclpci_put(struct aclpci_dev *d);
struct aclpci_dev *aclpci_get_by_minor(unsigned int minor, struct cdev *expected);
void aclpci_set_signal_task(struct aclpci_dev *d, struct task_struct *t);
void mask_kernel_irq(struct aclpci_dev *d);
ssize_t aclpci_exec_cmd(struct aclpci_dev *d, struct acl_cmd command, size_t count);
#endif
