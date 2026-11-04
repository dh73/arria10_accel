// Copyright (c) 2001-2016, Altera Corporation.
// All rights reserved.
//  
// This software is available to you under a choice of one of two
// licenses.  You may choose to be licensed under the terms of the GNU
// General Public License (GPL) Version 2, available from the file
// COPYING in the main directory of this source tree, or the
// BSD 3-Clause license below:
//  
//     Redistribution and use in source and binary forms, with or
//     without modification, are permitted provided that the following
//     conditions are met:
//  
//      - Redistributions of source code must retain the above
//        copyright notice, this list of conditions and the following
//        disclaimer.
//  
//      - Redistributions in binary form must reproduce the above
//        copyright notice, this list of conditions and the following
//        disclaimer in the documentation and/or other materials
//        provided with the distribution.
//  
//      - Neither Altera nor the names of its contributors may be 
//        used to endorse or promote products derived from this 
//        software without specific prior written permission.
//  
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//  

/* The process-context device gate is sem. DMA has a separate mutex and its
 * worker must never take sem. Publication and open references use the registry
 * lock; hard IRQ code uses only irq_lock/signal_lock, never either mutex. */
#ifdef ACLPCI_LIFECYCLE_TEST
#include "aclpci_lifecycle_test_kernel.h"
#else
#include "aclpci.h"
#include <linux/version.h>
#endif

MODULE_AUTHOR("Dmitry Denisenko");
MODULE_DESCRIPTION("Driver for Altera OpenCL Acceleration Boards");
/* account_locked_vm is GPL-only. Preserve the upstream dual-license notices,
 * but the linked Linux module must remain GPL-compatible. */
MODULE_LICENSE("GPL");

static int probe(struct pci_dev *dev, const struct pci_device_id *id);
static void remove(struct pci_dev *dev);

/* The historical match is intentionally unchanged. In particular the unknown
 * 1172:2494 / 1172:a151 image does NOT match this driver. */
static struct pci_device_id aclpci_ids[] = {
  { .vendor = ACL_PCI_ALTERA_VENDOR_ID, .device = PCI_ANY_ID, \
    .class = ACL_PCI_CLASSCODE, .class_mask = 0x00ff00ff, \
    .subvendor = ACL_PCI_SUBSYSTEM_VENDOR_ID, .subdevice = ACL_PCI_SUBSYSTEM_DEVICE_ID },
  { 0 },
};
MODULE_DEVICE_TABLE(pci, aclpci_ids);

static struct pci_driver aclpci_driver = {
  .name = DRIVER_NAME,
  .id_table = aclpci_ids,
  .probe = probe,
  .remove = remove,
  /* This prevents ordinary sysfs unbind, not hot removal or core teardown. */
  .driver = { .suppress_bind_attrs = true },
};

static const struct file_operations aclpci_fileops = {
  .owner = THIS_MODULE,
  .read = aclpci_read,
  .write = aclpci_write,
  .open = aclpci_open,
  .release = aclpci_close,
};

static int aclpci_major;
static struct class *aclpci_class;
static DEFINE_MUTEX(aclpci_registry_lock);
static struct aclpci_dev *aclpci_devices[ACLPCI_MAX_MINORS];
static LIST_HEAD(aclpci_quarantine);

static void aclpci_destroy(struct kref *ref)
{
  struct aclpci_dev *a = container_of(ref, struct aclpci_dev, ref);

  /* BARs, IRQ, work and DMA resources are already gone. An unretired request
   * retains the bound-device reference and never reaches this function. */
  aclpci_set_signal_task(a, NULL);
  pci_dev_put(a->upstream);
  pci_dev_put(a->pci_dev);
  kfree(a->buffer);
  kfree(a);
}

void aclpci_put(struct aclpci_dev *a)
{
  kref_put(&a->ref, aclpci_destroy);
}

struct aclpci_dev *aclpci_get_by_minor(unsigned int minor, struct cdev *expected)
{
  struct aclpci_dev *a = NULL;

  mutex_lock(&aclpci_registry_lock);
  if (minor < ACLPCI_MAX_MINORS && aclpci_devices[minor] &&
      aclpci_devices[minor]->cdev == expected) {
    a = aclpci_devices[minor];
    kref_get(&a->ref);
  }
  mutex_unlock(&aclpci_registry_lock);
  return a;
}

static int init_chrdev(struct aclpci_dev *a)
{
  unsigned int minor;
  int error = -ENOSPC;

  mutex_lock(&aclpci_registry_lock);
  for (minor = 0; minor < ACLPCI_MAX_MINORS; ++minor)
    if (!aclpci_devices[minor])
      break;
  if (minor == ACLPCI_MAX_MINORS)
    goto out;
  a->cdev_num = MKDEV(aclpci_major, minor);
  a->cdev = cdev_alloc();
  if (!a->cdev) {
    error = -ENOMEM;
    goto out;
  }
  a->cdev->owner = THIS_MODULE;
  a->cdev->ops = &aclpci_fileops;
  error = cdev_add(a->cdev, a->cdev_num, 1);
  if (error) {
    kobject_put(&a->cdev->kobj);
    a->cdev = NULL;
    goto out;
  }
  a->device = device_create(aclpci_class, &a->pci_dev->dev, a->cdev_num,
                             NULL, BOARD_NAME "%u", minor);
  if (IS_ERR(a->device)) {
    error = PTR_ERR(a->device);
    a->device = NULL;
    cdev_del(a->cdev);
    a->cdev = NULL;
    goto out;
  }
  /* No open can pass the registry lock until all initialization succeeded. */
  aclpci_devices[minor] = a;
  error = 0;
out:
  mutex_unlock(&aclpci_registry_lock);
  return error;
}

static void remove_chrdev(struct aclpci_dev *a)
{
  mutex_lock(&aclpci_registry_lock);
  if (a->cdev) {
    aclpci_devices[MINOR(a->cdev_num)] = NULL;
    device_destroy(aclpci_class, a->cdev_num);
    cdev_del(a->cdev);
    a->cdev = NULL;
    a->device = NULL;
  }
  mutex_unlock(&aclpci_registry_lock);
  /* The module-wide dev_t allocation is released only by module exit. */
}

void aclpci_set_signal_task(struct aclpci_dev *a, struct task_struct *task)
{
  struct task_struct *old;
  unsigned long flags;

  if (task)
    get_task_struct(task);
  spin_lock_irqsave(&a->signal_lock, flags);
  old = a->user_task;
  a->user_task = task;
  spin_unlock_irqrestore(&a->signal_lock, flags);
  if (old)
    put_task_struct(old);
}

void load_signal_info(struct aclpci_dev *a)
{
  memset(&a->signal_info, 0, sizeof(a->signal_info));
  a->signal_info.si_signo = SIG_INT_NOTIFY;
  a->signal_info.si_code = SI_QUEUE;
  a->signal_info_dma = a->signal_info;
}

static void __iomem *irq_enable_addr(struct aclpci_dev *a)
{
  return a->bar[ACL_PCI_CRA_BAR] + PCIE_CRA_IRQ_ENABLE;
}

static void mask_irq(struct aclpci_dev *a)
{
  unsigned long flags;
  u32 val;

  if (pci_channel_offline(a->pci_dev))
    return;
  spin_lock_irqsave(&a->irq_lock, flags);
  val = readl(irq_enable_addr(a));
  a->saved_kernel_irq_mask = ACL_PCIE_READ_BIT(val, ACL_PCIE_KERNEL_IRQ_VEC);
  writel(0, irq_enable_addr(a));
  readl(irq_enable_addr(a));
  spin_unlock_irqrestore(&a->irq_lock, flags);
}

void mask_kernel_irq(struct aclpci_dev *a)
{
  unsigned long flags;
  u32 val;

  if (!READ_ONCE(a->irq_registered) || pci_channel_offline(a->pci_dev))
    return;
  spin_lock_irqsave(&a->irq_lock, flags);
  val = readl(irq_enable_addr(a));
  writel(val & ~ACL_PCIE_GET_BIT(ACL_PCIE_KERNEL_IRQ_VEC), irq_enable_addr(a));
  readl(irq_enable_addr(a));
  spin_unlock_irqrestore(&a->irq_lock, flags);
}

void unmask_kernel_irq(struct aclpci_dev *a)
{
  unsigned long flags;
  u32 val;

  if (!a->online || a->io_blocked || !a->irq_registered ||
      pci_channel_offline(a->pci_dev))
    return;
  spin_lock_irqsave(&a->irq_lock, flags);
  val = readl(irq_enable_addr(a));
  writel(val | ACL_PCIE_GET_BIT(ACL_PCIE_KERNEL_IRQ_VEC), irq_enable_addr(a));
  readl(irq_enable_addr(a));
  spin_unlock_irqrestore(&a->irq_lock, flags);
}

/* A latched status bit can remain high after masking. Claim the enabled
 * kernel interrupt exactly once per explicit userspace arm. DMA interrupts
 * arriving later must not duplicate that kernel notification. */
static bool claim_kernel_irq(struct aclpci_dev *a)
{
  unsigned long flags;
  u32 enabled;
  bool claimed = false;

  spin_lock_irqsave(&a->irq_lock, flags);
  enabled = readl(irq_enable_addr(a));
  if (enabled & ACL_PCIE_GET_BIT(ACL_PCIE_KERNEL_IRQ_VEC)) {
    writel(enabled & ~ACL_PCIE_GET_BIT(ACL_PCIE_KERNEL_IRQ_VEC), irq_enable_addr(a));
    readl(irq_enable_addr(a));
    claimed = true;
  }
  spin_unlock_irqrestore(&a->irq_lock, flags);
  return claimed;
}

static void signal_kernel_completion(struct aclpci_dev *a)
{
  struct task_struct *task;
  struct kernel_siginfo info;
  unsigned long flags;

  memset(&info, 0, sizeof(info));
  info.si_signo = SIG_INT_NOTIFY;
  info.si_code = SI_QUEUE;
  spin_lock_irqsave(&a->signal_lock, flags);
  task = a->user_task;
  if (task)
    get_task_struct(task);
  info.si_int = READ_ONCE(a->signal_info.si_int);
  spin_unlock_irqrestore(&a->signal_lock, flags);
  if (task) {
    if (send_sig_info(SIG_INT_NOTIFY, &info, task) < 0)
      ++a->num_undelivered_signals;
    put_task_struct(task);
  }
}

static irqreturn_t aclpci_irq(int irq, void *dev_id)
{
  struct aclpci_dev *a = dev_id;
  u32 status;

  if (!a || !READ_ONCE(a->online) || READ_ONCE(a->pr_in_progress) ||
      pci_channel_offline(a->pci_dev))
    return IRQ_NONE;
  ++a->num_handled_interrupts;
  status = readl(a->bar[ACL_PCI_CRA_BAR] + PCIE_CRA_IRQ_STATUS);
  if (status == ~0U)
    return IRQ_NONE;
  if (ACL_PCIE_READ_BIT(status, ACL_PCIE_KERNEL_IRQ_VEC) && claim_kernel_irq(a)) {
    if (!POLLING)
      signal_kernel_completion(a);
  }
  /* A wakeup is not retirement. The worker inspects the exact in-flight table
   * under its mutex, with bounds/endian/barrier checks, before releasing it. */
  aclpci_dma_service_interrupt(a);
  return IRQ_HANDLED;
}

int init_irq(struct pci_dev *dev, void *dev_id)
{
  struct aclpci_dev *a = dev_id;
  unsigned long irq_flags = USE_MSI ? 0 : IRQF_SHARED;
  int error;

  if (!dev || !a)
    return -EINVAL;
  if (a->irq_registered)
    return 0;
  if (pci_channel_offline(dev))
    return -ENODEV;
  if (!a->dma_data.initialized || !a->dma_data.wq ||
      !a->dma_data.tables[0] || !a->dma_data.tables[1])
    return -EINVAL;
  if (!a->dma_data.contract_valid)
    return -EOPNOTSUPP;
  /* Tables, owner mutex and work must already be initialized. DMA masks were
   * configured at probe, BEFORE coherent allocation. */
  mask_irq(a);
  if (USE_MSI) {
    error = pci_enable_msi(dev);
    if (error)
      return error;
    a->msi_enabled = true;
  }
  a->irq_number = dev->irq;
  pci_read_config_byte(dev, PCI_REVISION_ID, &a->revision);
  pci_read_config_byte(dev, PCI_INTERRUPT_PIN, &a->irq_pin);
  pci_read_config_byte(dev, PCI_INTERRUPT_LINE, &a->irq_line);
  error = request_irq(a->irq_number, aclpci_irq, irq_flags, DRIVER_NAME, a);
  if (error) {
    if (a->msi_enabled) {
      pci_disable_msi(dev);
      a->msi_enabled = false;
    }
    return error;
  }
  WRITE_ONCE(a->irq_registered, true);
  /* Kernel IRQ admission is explicit (ENABLE_KERNEL_IRQ), never inherited
   * from an abandoned userspace session or an old loaded image. */
  a->saved_kernel_irq_mask = 0;
  return 0;
}

void release_irq(struct pci_dev *dev, void *dev_id)
{
  struct aclpci_dev *a = dev_id;

  /* Never call DMA finish before removing IRQ producers. This routine does
   * not flush a worker and is also usable by the serialized SAVE command. */
  if (a->irq_registered) {
    mask_irq(a);
    synchronize_irq(a->irq_number);
    free_irq(a->irq_number, a);
    WRITE_ONCE(a->irq_registered, false);
  }
  if (a->msi_enabled) {
    pci_disable_msi(dev);
    a->msi_enabled = false;
  }
  /* No unconditional device reset; IRQ silence is not DMA retirement. */
}

static void free_bars(struct aclpci_dev *a, struct pci_dev *dev)
{
  int i;

  for (i = 0; i < ACL_PCI_NUM_BARS; ++i) {
    if (a->bar[i])
      pci_iounmap(dev, a->bar[i]);
    a->bar[i] = NULL;
    a->bar_length[i] = 0;
  }
  a->global_mem_segment_addr = NULL;
}

static int map_bars(struct aclpci_dev *a, struct pci_dev *dev)
{
  int i;

  for (i = 0; i < ACL_PCI_NUM_BARS; ++i) {
    resource_size_t length = pci_resource_len(dev, i);

    if (!length)
      continue;
    if (!(pci_resource_flags(dev, i) & IORESOURCE_MEM) || length != (size_t)length)
      return -ENODEV;
    a->bar_length[i] = length;
    a->bar[i] = pci_iomap(dev, i, 0);
    if (!a->bar[i])
      return -ENOMEM;
  }
  if (!a->bar[ACL_PCIE_DMA_INTERNAL_BAR] ||
      a->bar_length[ACL_PCIE_DMA_INTERNAL_BAR] <
        ACL_PCIE_DMA_INTERNAL_CTR_BASE + ACL_PCIE_DMA_WR_CONTROL + sizeof(u32) ||
      !a->bar[ACL_PCI_CRA_BAR] ||
      a->bar_length[ACL_PCI_CRA_BAR] < PCIE_CRA_IRQ_ENABLE + sizeof(u32))
    return -ENODEV;
  return 0;
}

static int probe(struct pci_dev *dev, const struct pci_device_id *id)
{
  struct aclpci_dev *a;
  int error;

  /* Reject even dynamically added IDs outside the supplied narrow match. */
  if (dev->vendor != ACL_PCI_ALTERA_VENDOR_ID ||
      (dev->class & 0x00ff00ff) != (ACL_PCI_CLASSCODE & 0x00ff00ff) ||
      dev->subsystem_vendor != ACL_PCI_SUBSYSTEM_VENDOR_ID ||
      dev->subsystem_device != ACL_PCI_SUBSYSTEM_DEVICE_ID)
    return -ENODEV;
  mutex_lock(&aclpci_registry_lock);
  /* Hot-remove/rescan can create a new pci_dev for the same endpoint. A
   * pointer comparison cannot fence that reuse; any quarantine blocks all
   * new probes until platform recovery (which this driver cannot provide). */
  if (!list_empty(&aclpci_quarantine)) {
    mutex_unlock(&aclpci_registry_lock);
    return -EBUSY;
  }
  mutex_unlock(&aclpci_registry_lock);
  a = kzalloc(sizeof(*a), GFP_KERNEL);
  if (!a)
    return -ENOMEM;
  kref_init(&a->ref);
  aclpci_startup_revoke(&a->control_startup);
  sema_init(&a->sem, 1);
  spin_lock_init(&a->signal_lock);
  spin_lock_init(&a->irq_lock);
  INIT_LIST_HEAD(&a->quarantine_link);
  init_waitqueue_head(&a->wait_q);
  atomic_set(&a->status, 0);
  a->pci_dev = pci_dev_get(dev);
  a->upstream = pci_dev_get(dev->bus ? dev->bus->self : NULL);
  a->user_pid = -1;
  a->irq_number = -1;
  a->buffer = kmalloc(BUF_SIZE, GFP_KERNEL);
  if (!a->buffer) {
    error = -ENOMEM;
    goto put;
  }
  load_signal_info(a);
  error = pci_enable_device(dev);
  if (error)
    goto put;
  error = dma_set_mask_and_coherent(&dev->dev, DMA_BIT_MASK(64));
  if (error)
    goto disable;
  error = pci_request_regions(dev, DRIVER_NAME);
  if (error)
    goto disable;
  error = map_bars(a, dev);
  if (error)
    goto unmap;
  error = aclpci_dma_init(a);
  if (error)
    goto unmap;
  pci_set_drvdata(dev, a);
  a->online = true;
  /* No supplied shell contract establishes completion/no-late-write and DMA
   * context containment during PCI removal. Default is deliberately blocked:
   * metadata is available, but no IRQ/MMIO programming or bus-master enable.
   * There is no module parameter or userspace command that lifts this gate. */
  a->io_blocked = !a->dma_data.contract_valid;
  if (!a->io_blocked) {
    pci_set_master(dev);
    error = init_irq(dev, a);
    if (error)
      goto finish;
  }
  error = init_chrdev(a);
  if (error)
    goto irq;
  return 0;
irq:
  release_irq(dev, a);
finish:
  WRITE_ONCE(a->online, false);
  pci_set_drvdata(dev, NULL);
  aclpci_dma_finish(a); /* no cdev was published and no request was possible */
  pci_clear_master(dev);
unmap:
  free_bars(a, dev);
  pci_release_regions(dev);
disable:
  pci_disable_device(dev);
put:
  aclpci_put(a);
  return error;
}

static void remove(struct pci_dev *dev)
{
  struct aclpci_dev *a = pci_get_drvdata(dev);
  int error;

  if (!a || a->quarantined)
    return;
  down(&a->sem);
  WRITE_ONCE(a->online, false);
  a->removed = true;
  aclpci_startup_revoke(&a->control_startup);
  WRITE_ONCE(a->io_blocked, true);
  remove_chrdev(a);
  aclpci_dma_stop(a);
  up(&a->sem);
  /* Existing file contexts remain valid objects but every I/O sees ENODEV.
   * Close cannot deadlock the completion worker, which never takes sem. */
  release_irq(dev, a);
  error = a->control_debt ? -EBUSY : aclpci_dma_finish(a);
  aclpci_set_signal_task(a, NULL);
  if (error) {
    a->quarantined = true;
    mutex_lock(&aclpci_registry_lock);
    list_add_tail(&a->quarantine_link, &aclpci_quarantine);
    mutex_unlock(&aclpci_registry_lock);
    /* The active file context already pins this module. Give quarantine its
     * own permanent reference as well; there is no supplied safe reclaim API.
     * This does not veto driver-core removal or preserve an IOMMU domain. */
    __module_get(THIS_MODULE);
    /* Keep base ref, mappings, tables, BAR reservations and device allocation. */
    dev_err(&dev->dev, "unretired DMA/control custody retained; PCI remove cannot veto IOMMU teardown; platform containment is required, rebinding is forbidden\n");
    return;
  }
  pci_set_drvdata(dev, NULL);
  pci_clear_master(dev);
  free_bars(a, dev);
  pci_release_regions(dev);
  pci_disable_device(dev);
  aclpci_put(a);
}

static int __init aclpci_init(void)
{
  dev_t dev;
  int error;

  error = alloc_chrdev_region(&dev, 0, ACLPCI_MAX_MINORS, BOARD_NAME);
  if (error)
    return error;
  aclpci_major = MAJOR(dev);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
  aclpci_class = class_create(DRIVER_NAME);
#else
  aclpci_class = class_create(THIS_MODULE, DRIVER_NAME);
#endif
  if (IS_ERR(aclpci_class)) {
    error = PTR_ERR(aclpci_class);
    goto unreg;
  }
  error = pci_register_driver(&aclpci_driver);
  if (!error)
    return 0;
  class_destroy(aclpci_class);
unreg:
  unregister_chrdev_region(dev, ACLPCI_MAX_MINORS);
  return error;
}

static void __exit aclpci_exit(void)
{
  pci_unregister_driver(&aclpci_driver);
  class_destroy(aclpci_class);
  unregister_chrdev_region(MKDEV(aclpci_major, 0), ACLPCI_MAX_MINORS);
}

module_init(aclpci_init);
module_exit(aclpci_exit);
