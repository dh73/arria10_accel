/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_LIFECYCLE_TEST_KERNEL_H
#define ACLPCI_LIFECYCLE_TEST_KERNEL_H
/* Executable dependency doubles, not kernel-ABI declarations. This includes
 * the actual aclpci.c implementation and records ordering/lifetime effects. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#define __iomem
#define __user
#define __init
#define __exit
#define GFP_KERNEL 0
#define THIS_MODULE ((void *)1)
#define MODULE_AUTHOR(x)
#define MODULE_DESCRIPTION(x)
#define MODULE_LICENSE(x)
#define MODULE_DEVICE_TABLE(a,b)
#define module_init(x)
#define module_exit(x)
#define KERNEL_VERSION(a,b,c) (((a)<<16)|((b)<<8)|(c))
#define LINUX_VERSION_CODE KERNEL_VERSION(7,2,14)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define READ_ONCE(x) __atomic_load_n(&(x), __ATOMIC_RELAXED)
#define WRITE_ONCE(x,v) __atomic_store_n(&(x), (v), __ATOMIC_RELAXED)
#define ERR_PTR(x) ((void *)(intptr_t)(x))
#define PTR_ERR(x) ((int)(intptr_t)(x))
#define IS_ERR(x) ((uintptr_t)(x) >= (uintptr_t)-4095)
#define MKDEV(a,b) (((dev_t)(a)<<20)|(b))
#define MAJOR(a) ((unsigned int)((a)>>20))
#define MINOR(a) ((unsigned int)((a)&0xfffff))
#define DMA_BIT_MASK(n) UINT64_MAX
#define PCI_ANY_ID UINT32_MAX
#define IRQF_SHARED 1
#define IRQ_NONE 0
#define IRQ_HANDLED 1
#define IORESOURCE_MEM 1
#define PCI_REVISION_ID 8
#define PCI_INTERRUPT_PIN 61
#define PCI_INTERRUPT_LINE 60
#define SI_QUEUE (-1)
#define DRIVER_NAME "altr_aclpci_cvp_drv"
#define BOARD_NAME "acla10_ref"
#define ACLPCI_MAX_MINORS 16
#define ACL_PCI_ALTERA_VENDOR_ID 0x1172
#define ACL_PCI_CLASSCODE 0xEA0001
#define ACL_PCI_SUBSYSTEM_VENDOR_ID 0x1172
#define ACL_PCI_SUBSYSTEM_DEVICE_ID 0x0001
#define ACL_PCI_NUM_BARS 5
#define ACL_PCI_CRA_BAR 4
#define ACL_PCIE_DMA_INTERNAL_BAR 0
#define ACL_PCIE_DMA_INTERNAL_CTR_BASE 0
#define ACL_PCIE_DMA_WR_CONTROL 0x118
#define PCIE_CRA_IRQ_STATUS 0xcf90
#define PCIE_CRA_IRQ_ENABLE 0xcfa0
#define ACL_PCIE_KERNEL_IRQ_VEC 0
#define ACL_PCIE_READ_BIT(w,b) (((w)>>(b))&1)
#define ACL_PCIE_GET_BIT(b) (1U<<(b))
#define USE_MSI 1
#define POLLING 0
#define SIG_INT_NOTIFY 44
#define BUF_SIZE 4096
#define loff_t test_loff_t

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint64_t resource_size_t;
typedef long long test_loff_t;
typedef int irqreturn_t;
struct class { int unused; };
struct device { int unused; };
struct kref { unsigned int refs; };
struct mutex { bool held; };
struct semaphore { unsigned int count; };
struct list_head { struct list_head *next, *prev; };
struct task_struct { unsigned int refs; };
struct kernel_siginfo { int si_signo, si_code, si_int, si_errno; };
struct pci_dev;
struct pci_bus { struct pci_dev *self; };
struct pci_dev {
    struct device dev;
    struct pci_bus *bus;
    unsigned int vendor, class, subsystem_vendor, subsystem_device;
    unsigned int refs;
    int irq;
    bool enabled, regions, msi, master, disconnected, frozen;
    void *data;
    resource_size_t lengths[ACL_PCI_NUM_BARS];
};
struct inode { int unused; };
struct file { int unused; };
struct file_operations {
    void *owner;
    ssize_t (*read)(struct file *, char *, size_t, loff_t *);
    ssize_t (*write)(struct file *, const char *, size_t, loff_t *);
    int (*open)(struct inode *, struct file *);
    int (*release)(struct inode *, struct file *);
};
struct kobject { int unused; };
struct cdev { struct kobject kobj; void *owner; const struct file_operations *ops; };
struct pci_device_id { unsigned int vendor, device, class, class_mask, subvendor, subdevice; };
struct pci_driver {
    const char *name;
    const struct pci_device_id *id_table;
    int (*probe)(struct pci_dev *, const struct pci_device_id *);
    void (*driver_remove)(struct pci_dev *);
    struct { bool suppress_bind_attrs; } driver;
};
struct aclpci_dma { bool contract_valid, initialized, active; void *wq, *tables[2]; };
struct aclpci_dev {
    struct aclpci_file *control_owner;
    bool control_debt;
    struct kref ref;
    bool online, removed, io_blocked, saved_state, irq_registered, msi_enabled, quarantined;
    int irq_number;
    struct list_head quarantine_link;
    struct mutex signal_lock, irq_lock;
    struct semaphore sem;
    struct pci_dev *pci_dev, *upstream;
    struct cdev *cdev;
    dev_t cdev_num;
    struct device *device;
    char *buffer;
    void *bar[ACL_PCI_NUM_BARS];
    size_t bar_length[ACL_PCI_NUM_BARS];
    void *global_mem_segment_addr;
    struct task_struct *user_task;
    struct kernel_siginfo signal_info, signal_info_dma;
    struct aclpci_dma dma_data;
    int user_pid, irq_pin, irq_line, revision, wait_q, status;
    int pr_in_progress;
    char saved_kernel_irq_mask;
    size_t num_handled_interrupts, num_undelivered_signals;
};

enum fault {
    FAIL_NONE, FAIL_STATE, FAIL_BUFFER, FAIL_ENABLE, FAIL_MASK, FAIL_REGIONS,
    FAIL_MAP1, FAIL_MAP2, FAIL_DMA, FAIL_CDEV, FAIL_CDEV_ADD, FAIL_NODE,
    FAIL_MSI, FAIL_IRQ
};
static enum fault injected;
static unsigned int heap_objects, cdev_objects, node_objects, mapped_bars;
static unsigned int dma_objects, module_refs, map_calls, queued, notifications;
static bool test_contract, irq_requested;
static unsigned int writes;
static char order[128];
static unsigned int order_count;
static struct device *mock_node;
static struct class mock_class;
static int registered_irq;
static void *registered_owner;
static irqreturn_t (*registered_handler)(int, void *);

static void event(char e) { assert(order_count + 1 < sizeof(order)); order[order_count++] = e; order[order_count] = 0; }
static void *kzalloc(size_t n, int flags) { (void)flags; if (injected == FAIL_STATE) return NULL; ++heap_objects; return calloc(1,n); }
static void *kmalloc(size_t n, int flags) { (void)flags; if (injected == FAIL_BUFFER) return NULL; ++heap_objects; return malloc(n); }
static void kfree(void *p) { if (p) { assert(heap_objects); --heap_objects; free(p); } }
static void kref_init(struct kref *r) { r->refs = 1; }
static void kref_get(struct kref *r) { assert(r->refs); ++r->refs; }
static void kref_put(struct kref *r, void (*release)(struct kref *)) { assert(r->refs); if (!--r->refs) release(r); }
#define DEFINE_MUTEX(n) struct mutex n
static void mutex_lock(struct mutex *m) { assert(!m->held); m->held = true; }
static void mutex_unlock(struct mutex *m) { assert(m->held); m->held = false; }
static void sema_init(struct semaphore *s, int n) { s->count = n; }
static void down(struct semaphore *s) { assert(s->count == 1); --s->count; }
static void up(struct semaphore *s) { assert(!s->count); ++s->count; }
#define spin_lock_init(m) ((m)->held = false)
#define spin_lock_irqsave(m,f) do { (f)=0; mutex_lock(m); } while (0)
#define spin_unlock_irqrestore(m,f) do { (void)(f); mutex_unlock(m); } while (0)
#define init_waitqueue_head(q) (*(q)=0)
#define atomic_set(a,n) (*(a)=(n))
#define LIST_HEAD(n) struct list_head n = { &(n), &(n) }
static void INIT_LIST_HEAD(struct list_head *l) { l->next = l->prev = l; }
static bool list_empty(struct list_head *l) { return l->next == l; }
static void list_add_tail(struct list_head *n, struct list_head *h) { n->prev=h->prev; n->next=h; h->prev->next=n; h->prev=n; }
static void list_del(struct list_head *n) { n->prev->next=n->next; n->next->prev=n->prev; }
#define list_for_each_entry(p,h,m) \
    for (struct list_head *it=(h)->next; it!=(h) && ((p)=container_of(it,__typeof__(*(p)),m),1); it=it->next)
static struct pci_dev *pci_dev_get(struct pci_dev *p) { if(p) ++p->refs; return p; }
static void pci_dev_put(struct pci_dev *p) { if(p) { assert(p->refs); --p->refs; } }
static void get_task_struct(struct task_struct *p) { assert(p); ++p->refs; }
static void put_task_struct(struct task_struct *p) { assert(p && p->refs); --p->refs; }
static int send_sig_info(int sig, struct kernel_siginfo *info, struct task_struct *p) { assert(sig==44 && info->si_code==SI_QUEUE && p->refs); ++notifications; return 0; }
static struct cdev *cdev_alloc(void) { if(injected==FAIL_CDEV) return NULL; ++cdev_objects; return calloc(1,sizeof(struct cdev)); }
static int cdev_add(struct cdev *c, dev_t n, int count) { (void)c; (void)n; assert(count==1); return injected==FAIL_CDEV_ADD ? -EIO : 0; }
static void cdev_del(struct cdev *c) { assert(cdev_objects); --cdev_objects; free(c); }
static void kobject_put(struct kobject *k) { cdev_del(container_of(k,struct cdev,kobj)); }
static struct device *device_create(struct class *c, struct device *parent, dev_t n, void *data, const char *fmt, unsigned int minor) { (void)c;(void)parent;(void)n;(void)data;(void)fmt;(void)minor; if(injected==FAIL_NODE) return ERR_PTR(-EIO); assert(!mock_node); ++node_objects; return mock_node=calloc(1,sizeof(*mock_node)); }
static void device_destroy(struct class *c, dev_t n) { (void)c;(void)n; assert(node_objects && mock_node); --node_objects; free(mock_node); mock_node=NULL; }
static bool pci_channel_offline(struct pci_dev *p) { return p->disconnected || p->frozen; }
static u32 readl(const void *p) { u32 value; memcpy(&value,p,sizeof(value)); return value; }
static void writel(u32 v, void *p) { ++writes; event(v ? 'U' : 'M'); memcpy(p,&v,sizeof(v)); }
static int pci_enable_msi(struct pci_dev *p) { if(injected==FAIL_MSI) return -EIO; assert(!p->msi); p->msi=true; return 0; }
static void pci_disable_msi(struct pci_dev *p) { assert(p->msi); p->msi=false; event('I'); }
static void pci_read_config_byte(struct pci_dev *p, int offset, void *out) { (void)p; *(u8 *)out = offset==PCI_INTERRUPT_LINE ? 22 : 1; }
static int request_irq(int irq, irqreturn_t (*handler)(int,void *), unsigned long flags, const char *name, void *owner) {
    struct aclpci_dev *a=owner; (void)flags;(void)name;
    assert(a->dma_data.initialized && a->signal_info.si_signo==44);
    assert(readl(a->bar[4]+PCIE_CRA_IRQ_ENABLE)==0);
    if(injected==FAIL_IRQ) return -EIO;
    assert(!irq_requested); irq_requested=true; registered_irq=irq;
    registered_owner=owner; registered_handler=handler; event('R'); return 0;
}
static void synchronize_irq(int irq) { assert(irq_requested && irq==registered_irq); event('S'); }
static void free_irq(int irq, void *owner) { assert(irq_requested && irq==registered_irq && owner==registered_owner); event('F'); irq_requested=false; registered_handler=NULL; registered_owner=NULL; }
static int pci_enable_device(struct pci_dev *p) { if(injected==FAIL_ENABLE) return -EIO; p->enabled=true; return 0; }
static void pci_disable_device(struct pci_dev *p) { assert(p->enabled); p->enabled=false; event('E'); }
static int dma_set_mask_and_coherent(struct device *d, u64 mask) { (void)d;(void)mask; return injected==FAIL_MASK ? -EIO : 0; }
static int pci_request_regions(struct pci_dev *p, const char *name) { (void)name; if(injected==FAIL_REGIONS) return -EIO; p->regions=true; return 0; }
static void pci_release_regions(struct pci_dev *p) { assert(p->regions); p->regions=false; event('G'); }
static resource_size_t pci_resource_len(struct pci_dev *p, int i) { return p->lengths[i]; }
static unsigned long pci_resource_flags(struct pci_dev *p, int i) { (void)p;(void)i; return IORESOURCE_MEM; }
static void *pci_iomap(struct pci_dev *p, int i, int max) { (void)max; ++map_calls; if((injected==FAIL_MAP1 && map_calls==1)||(injected==FAIL_MAP2 && map_calls==2)) return NULL; ++mapped_bars; return calloc(1,p->lengths[i]); }
static void pci_iounmap(struct pci_dev *p, void *bar) { (void)p; assert(mapped_bars); --mapped_bars; free(bar); event('B'); }
static void pci_set_drvdata(struct pci_dev *p, void *d) { p->data=d; }
static void *pci_get_drvdata(struct pci_dev *p) { return p->data; }
static void pci_set_master(struct pci_dev *p) { p->master=true; }
static void pci_clear_master(struct pci_dev *p) { p->master=false; }
static void __module_get(void *m) { (void)m; ++module_refs; }
#define dev_err(d,...) do { (void)(d); event('Q'); } while (0)
static int alloc_chrdev_region(dev_t *n, int minor, int count, const char *name) { (void)minor;(void)count;(void)name; *n=MKDEV(200,0); return 0; }
static void unregister_chrdev_region(dev_t n, int count) { (void)n; assert(count==ACLPCI_MAX_MINORS); }
#define class_create(...) (&mock_class)
static void class_destroy(struct class *c) { assert(c==&mock_class); }
static int pci_register_driver(struct pci_driver *d) { assert(d->driver.suppress_bind_attrs); return 0; }
static void pci_unregister_driver(struct pci_driver *d) { (void)d; }
static ssize_t aclpci_read(struct file *f,char *p,size_t n,loff_t *off) { (void)f;(void)p;(void)n;(void)off; return 0; }
static ssize_t aclpci_write(struct file *f,const char *p,size_t n,loff_t *off) { (void)f;(void)p;(void)n;(void)off; return 0; }
static int aclpci_open(struct inode *i,struct file *f) { (void)i;(void)f; return 0; }
static int aclpci_close(struct inode *i,struct file *f) { (void)i;(void)f; return 0; }
static int aclpci_dma_init(struct aclpci_dev *a) { if(injected==FAIL_DMA) return -ENOMEM; a->dma_data.initialized=true; a->dma_data.wq=(void *)1; a->dma_data.tables[0]=(void *)1; a->dma_data.tables[1]=(void *)1; a->dma_data.contract_valid=test_contract; dma_objects+=3; return 0; }
static int aclpci_dma_stop(struct aclpci_dev *a) { assert(!a->sem.count); event('T'); return a->dma_data.active ? -EINPROGRESS : 0; }
static int aclpci_dma_finish(struct aclpci_dev *a) {
    assert(!irq_requested && a->sem.count); event('D');
    if(a->dma_data.active) return -EBUSY;
    if(a->dma_data.initialized) { assert(dma_objects>=3); dma_objects-=3; a->dma_data.initialized=false; }
    return 0;
}
static irqreturn_t aclpci_dma_service_interrupt(struct aclpci_dev *a) { assert(a->dma_data.initialized); ++queued; return IRQ_HANDLED; }
void aclpci_set_signal_task(struct aclpci_dev *,struct task_struct *);
void aclpci_put(struct aclpci_dev *);
#endif
