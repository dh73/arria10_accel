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

/* Implementation of all I/O functions except DMA transfers.
 * See aclpci_dma.c for DMA code.
 */

#ifdef ACLPCI_FILEIO_TEST
#include "aclpci_fileio_test_kernel.h"
#else
#include <linux/limits.h>
#include <linux/slab.h>
#include <linux/jiffies.h>
#include <linux/sched.h>
#include <asm/io.h> // __raw_write, __raw_read
#include "aclpci.h"
#endif


static ssize_t aclpci_rw_large (void *dev_addr, void __user* use_addr, ssize_t len, char *buffer, int reading, int access_le);



/* Given (bar_id, device_addr) pair, make sure they're valid and return
 * the resulting address. errno will contain error code, if any. */
void* aclpci_get_checked_addr (int bar_id, void *device_addr, size_t count,
                               struct aclpci_dev *aclpci, ssize_t *errno,
                               int print_error_msg) {

  if (bar_id < 0 || bar_id >= ACL_PCI_NUM_BARS) {
    ACL_DEBUG (KERN_WARNING "Requested read/write from BAR #%d. Only have %d BARs!",
               bar_id, ACL_PCI_NUM_BARS);
    *errno = -EFAULT;
    return 0;
  }
  /* Make sure the final address is within range */
  if (!aclpci->bar[bar_id] ||
      (unsigned long)device_addr > aclpci->bar_length[bar_id] ||
      count > aclpci->bar_length[bar_id] - (unsigned long)device_addr) {
    if (print_error_msg) {
      ACL_DEBUG (KERN_WARNING "Requested read/write from BAR #%d from range (0x%lx, 0x%lx). Length is %lu. BAR length is only %lu!",
                 bar_id, 
                 (unsigned long)device_addr,
                 (unsigned long)device_addr + count, 
                 count,
                 aclpci->bar_length[bar_id]);
    }
    *errno = -EFAULT;
    return 0;
  }

  *errno = 0;
  return (void*)(aclpci->bar[bar_id] + (unsigned long)device_addr);  
}


/* Compute address that contains memory window segment control */
static void *get_segment_ctrl_addr (struct aclpci_dev *aclpci) {

  void *dev_addr = 0;
  ssize_t errno = 0;
  void *ctrl_addr = (void*) (ssize_t)ACL_PCIE_MEMWINDOW_CRA;

  ACL_VERBOSE_DEBUG (KERN_DEBUG "get_segment_ctrl_addr ctrl_addr = %llx.", ctrl_addr);
  dev_addr = aclpci_get_checked_addr (ACL_PCIE_MEMWINDOW_BAR, ctrl_addr, sizeof(u64), aclpci, &errno, 1);
  if (errno != 0) {
    ACL_DEBUG (KERN_DEBUG "ERROR: ctrl_addr %p failed check", ctrl_addr);
    return NULL;
  }
  return dev_addr;
}


static void aclpci_set_segment_by_val (struct aclpci_dev *aclpci, u64 new_val) {

  void *ctrl_addr =  aclpci->global_mem_segment_addr;
  if (ctrl_addr == NULL) {
    return;
  }
  
  writeq(new_val, ctrl_addr);
  aclpci->global_mem_segment = new_val;
  aclpci->global_mem_segment_valid = true;
  ACL_VERBOSE_DEBUG (KERN_DEBUG " Changed global memory segment to %llu.", new_val);
}


/* The context can outlive struct file while a DMA request owns it. Its
 * destructor never flushes work or takes sem, including on the DMA worker. */
static void aclpci_file_release_ref(struct kref *ref)
{
  struct aclpci_file *owner = container_of(ref, struct aclpci_file, ref);
  struct aclpci_dev *aclpci = owner->aclpci;

  kfree(owner);
  aclpci_put(aclpci);
  module_put(THIS_MODULE);
}

void aclpci_file_get(struct aclpci_file *owner)
{
  kref_get(&owner->ref);
}

void aclpci_file_put(struct aclpci_file *owner)
{
  kref_put(&owner->ref, aclpci_file_release_ref);
}

/* Internal lifecycle custody. sem spans these calls and the control operation.
 * The extra file reference preserves device/module lifetime on uncertain close.
 * Neither a successful mailbox response nor DMA idle discharges control debt. */
int aclpci_control_claim(struct aclpci_file *owner)
{
  struct aclpci_dev *a;
  int result = 0;
  if (!owner) return -EINVAL;
  a = owner->aclpci;
  if (!a->online || a->removed || owner->closed) return -ENODEV;
  if (a->control_owner) return -EBUSY;
  if (!a->io_blocked || a->pr_in_progress || !a->dma_data.initialized)
    return -EBUSY;
  mutex_lock(&a->dma_data.lock);
  if (a->dma_data.active || a->dma_data.fault || a->control_debt)
    result = -EBUSY;
  else {
    aclpci_file_get(owner);
    a->control_owner = owner;
  }
  mutex_unlock(&a->dma_data.lock);
  return result;
}

int aclpci_control_mark_issued(struct aclpci_file *owner)
{
  struct aclpci_dev *a;
  if (!owner) return -EINVAL;
  a = owner->aclpci;
  if (!a->online || a->removed || owner->closed) return -ENODEV;
  if (a->control_owner != owner) return -EPERM;
  if (!a->io_blocked || a->pr_in_progress) return -EBUSY;
  /* Sticky even when the subsequent MMIO result is uncertain. This does not
   * authorize MMIO: image/reset admission must still be checked separately. */
  a->control_debt = true;
  return 0;
}

int aclpci_control_release_unused(struct aclpci_file *owner)
{
  struct aclpci_dev *a;
  if (!owner) return -EINVAL;
  a = owner->aclpci;
  if (a->control_owner != owner) return -EPERM;
  if (a->control_debt) return -EBUSY;
  a->control_owner = NULL;
  aclpci_file_put(owner);
  return 0;
}

int aclpci_open(struct inode *inode, struct file *file)
{
  struct aclpci_file *owner;
  struct aclpci_dev *aclpci;
  int result = 0;

  aclpci = aclpci_get_by_minor(iminor(inode), inode->i_cdev);
  if (!aclpci)
    return -ENODEV;
  owner = kzalloc(sizeof(*owner), GFP_KERNEL);
  if (!owner) {
    aclpci_put(aclpci);
    return -ENOMEM;
  }
  /* The fops module reference ends at release(); this one lasts until the
   * independent DMA/file context is released, possibly much later. */
  if (!try_module_get(THIS_MODULE)) {
    kfree(owner);
    aclpci_put(aclpci);
    return -ENODEV;
  }
  kref_init(&owner->ref);
  owner->aclpci = aclpci;
  if (down_interruptible(&aclpci->sem)) {
    result = -ERESTARTSYS;
    goto put;
  }
  if (!aclpci->online || aclpci->removed) {
    result = -ENODEV;
    goto unlock;
  }
  if (aclpci->num_handles_open == INT_MAX) {
    result = -EOVERFLOW;
    goto unlock;
  }
  if (!aclpci->num_handles_open) {
    aclpci->global_mem_segment_addr = get_segment_ctrl_addr(aclpci);
    if (!aclpci->global_mem_segment_addr) {
      result = -ENODEV;
      goto unlock;
    }
  }
  ++aclpci->num_handles_open;
  aclpci_set_signal_task(aclpci, current);
  file->private_data = owner;
unlock:
  up(&aclpci->sem);
put:
  if (result)
    aclpci_file_put(owner);
  return result;
}

int aclpci_close(struct inode *inode, struct file *file)
{
  struct aclpci_file *owner = file->private_data;
  struct aclpci_dev *aclpci;

  if (!owner)
    return 0;
  aclpci = owner->aclpci;
  /* release must finish its bookkeeping even when the caller has a signal. */
  down(&aclpci->sem);
  owner->closed = true;
  if (aclpci->control_owner == owner)
    aclpci_control_release_unused(owner); /* Debt intentionally retains custody. */
  --aclpci->num_handles_open;
  if (!aclpci->num_handles_open) {
    if (aclpci->online) {
      if (aclpci->irq_registered)
        mask_kernel_irq(aclpci);
      /* This only cancels further batches. In-flight memory stays owned.
       * Keep IRQ/workqueue alive so the current table can really retire. */
      aclpci_dma_stop(aclpci);
    }
    aclpci_set_signal_task(aclpci, NULL);
  }
  file->private_data = NULL;
  up(&aclpci->sem);
  aclpci_file_put(owner);
  return 0;
}


/* Read a small number of bytes and put them into user space */
static ssize_t aclpci_read_small (void *read_addr, void __user* dest_addr, ssize_t len, int access_le) {

  ssize_t copy_res = 0;
  switch (len) {
  case 1: {
    u8 d = readb ( read_addr );
    copy_res = copy_to_user ( dest_addr, &d, sizeof(d) );
    break;
  }
  case 2: {
    u16 d = access_le ? readw ( read_addr ) : __raw_readw ( read_addr );
    copy_res = copy_to_user ( dest_addr, &d, sizeof(d) );
    break;
  }
  case 4: {
    u32 d = access_le ? readl ( read_addr ) : __raw_readl ( read_addr );
    copy_res = copy_to_user ( dest_addr, &d, sizeof(d) );
    break;
  }
  case 8: {
    u32 ibuffer[2];
    if(access_le){
      ibuffer[0] = readl (((u32*)read_addr));
      ibuffer[1] = readl (((u32*)read_addr)+1);
    }else {
      ibuffer[0] = __raw_readl(((u32*)read_addr));
      mb();
      ibuffer[1] = __raw_readl(((u32*)read_addr)+1);
    }

    copy_res = copy_to_user ( dest_addr, ibuffer, sizeof(ibuffer) );
    break;
  }
  default:
    break;
  }
  
  if(!access_le){
    mb();
  }

  if (copy_res) {
    return -EFAULT;
  } else {
    return 0;
  }
}


/* Write a small number of bytes taken from user space */
static ssize_t aclpci_write_small (void *write_addr, void __user* src_addr, ssize_t len, int access_le) {

  ssize_t copy_res = 0;
  switch (len) {
  case 1: {
    u8 d;
    copy_res = copy_from_user ( &d, src_addr, sizeof(d) );
    if (copy_res)
      return -EFAULT;
    writeb ( d, write_addr );
    break;
  }
  case 2: {
    u16 d;
    copy_res = copy_from_user ( &d, src_addr, sizeof(d) );
    if (copy_res)
      return -EFAULT;
    if(access_le){
      writew ( d, write_addr );
    } else {
      __raw_writew ( d, write_addr );
      mb();
    }
    break;
  }
  case 4: {
    u32 d;
    copy_res = copy_from_user ( &d, src_addr, sizeof(d) );
    if (copy_res)
      return -EFAULT;
    if(access_le){
      writel ( d, write_addr );
    } else {
      __raw_writel ( d, write_addr );
      mb();
    }
    break;
  }
  case 8: {
    u32 ibuffer[2];
    copy_res = copy_from_user (ibuffer, src_addr, sizeof(ibuffer));
    if (copy_res)
      return -EFAULT;
    if(access_le){
      writel ( ibuffer[0], (u32*)write_addr);
      writel ( ibuffer[1], ((u32*)write_addr) + 1 );
    }else {
      __raw_writel( ibuffer[0], (u32*)write_addr);
      mb();
      __raw_writel( ibuffer[1], ((u32*)write_addr) + 1 );
    }
    break;
  }
  default:
    break;
  }

  if (copy_res) {
    return -EFAULT;
  } else {
    return 0;
  }
}



/* Read or Write arbitrary length sequency starting at read_addr and put it into
 * user space at dest_addr. if 'reading' is set to 1, doing the read. If 0, doing
 * the write. */
static ssize_t aclpci_rw_large (void *dev_addr, void __user* user_addr,
                                  ssize_t len, char *buffer, int reading, int access_le) {
  size_t bytes_left = len;
  size_t i, num_missed;
  u32 *ibuffer = (u32*)buffer;
  char *cbuffer;
  size_t offset, num_to_read;
  size_t chunk = BUF_SIZE;
  
  
  /* Reading upto BUF_SIZE values, one int at a time, and then transfer
   * the buffer at once to user space. Repeat as necessary. */
  while (bytes_left > 0) {
    if (bytes_left < BUF_SIZE) {
      chunk = bytes_left;
    } else {
      chunk = BUF_SIZE;
    }
    
    if (!reading) {
      if (copy_from_user (ibuffer, user_addr, chunk)) {
        return -EFAULT;
      }
    }

    /* Read one u32 at a time until fill the buffer. Then copy the whole
     * buffer at once to user space. */
    num_to_read = chunk / sizeof(u32);
    for (i = 0; i < num_to_read; i++) {
      if (reading) {
        if(access_le){
          ibuffer[i] = readl (((u32*)dev_addr) + i);
        }else {
          ibuffer[i] = __raw_readl(((u32*)dev_addr) + i);
          mb();
        }
      } else {
        if(access_le){
          writel ( ibuffer[i], ((u32*)dev_addr) + i );
        }else {
          __raw_writel( ibuffer[i], ((u32*)dev_addr) + i );
          mb();
        }
      }
    }
    
    /* If length is not a multiple of sizeof(u32), will miss last few bytes.
     * In that case, read it one byte at a time. This can only happen on 
     * last iteration of the while() loop. */
    offset = num_to_read * sizeof(u32);
    num_missed = chunk - offset;
    cbuffer = (char*)(ibuffer + num_to_read);
    
    for (i = 0; i < num_missed; i++) {
      if (reading) {
        cbuffer[i] = readb ( (u8*)(dev_addr) + offset + i );
      } else {
        writeb ( cbuffer[i], (u8*)(dev_addr) + offset + i );
      }
    }
    
    if (reading) {
      if (copy_to_user (user_addr, ibuffer, chunk)) {
        return -EFAULT;
      }
    }
    
    dev_addr += chunk;
    user_addr += chunk;
    bytes_left -= chunk;
  }
  
  return 0;
}

/* Set CRA window so raw_user_ptr is "visible" to the BAR.
 * Return pointer to use to access the user memory */
static void* aclpci_set_segment (struct aclpci_dev *aclpci, void * raw_user_ptr) {

  unsigned long raw = (unsigned long)raw_user_ptr;
  u64 cur_segment = raw & ~((u64)ACL_PCIE_MEMWINDOW_SIZE - 1);
  aclpci_set_segment_by_val (aclpci, cur_segment);  

  /* Can use the return value in all read/write functions in this file now */
  return (void *)(unsigned long)(ACL_PCIE_MEMWINDOW_BASE +
                               raw % ACL_PCIE_MEMWINDOW_SIZE);
}


/* Both start and end, user and device addresses must be 
 * 64-byte aligned to use DMA */
static int aligned_request (struct acl_cmd *cmd, size_t count) {
  
  return (( (unsigned long)cmd->user_addr   & DMA_ALIGNMENT_BYTE_MASK) | 
          ( (unsigned long)cmd->device_addr & DMA_ALIGNMENT_BYTE_MASK) |
          ( count                           & DMA_ALIGNMENT_BYTE_MASK)
         ) == 0;
}                           


/* Only the request owner may publish DMA tables. Raw BAR access must not
 * bypass its lock, and reset/PR/IRQ control must use driver lifecycle paths.
 * The intervals use only registers present in the supplied historical ABI. */
static bool overlaps(unsigned long offset, size_t bytes,
                     unsigned long start, size_t length)
{
  return bytes && offset < start + length &&
         (offset >= start || bytes > start - offset);
}

#include "platform_control_abi.h"

static bool protected_write(const struct acl_cmd *cmd, size_t size)
{
  unsigned long offset = (unsigned long)cmd->device_addr;

  if (cmd->bar_id == ACLPCI_PLATFORM_CONTROL_BAR &&
      (overlaps(offset, size, ACLPCI_PLATFORM_FENCE_BASE,
                ACLPCI_PLATFORM_FENCE_BYTES) ||
       overlaps(offset, size, ACLPCI_PLATFORM_COMMAND_BASE,
                ACLPCI_PLATFORM_COMMAND_BYTES) ||
       overlaps(offset, size, ACLPCI_PLATFORM_CONTEXT_BASE,
                ACLPCI_PLATFORM_CONTEXT_BYTES)))
    return true;

  if (cmd->bar_id == ACL_PCIE_DMA_INTERNAL_BAR &&
      (overlaps(offset, size, ACL_PCIE_DMA_INTERNAL_CTR_BASE +
                ACL_PCIE_DMA_RC_RD_DESC_BASE_LOW,
                ACL_PCIE_DMA_RD_CONTROL + sizeof(u32) -
                ACL_PCIE_DMA_RC_RD_DESC_BASE_LOW) ||
       overlaps(offset, size, ACL_PCIE_DMA_INTERNAL_CTR_BASE +
                ACL_PCIE_DMA_RC_WR_DESC_BASE_LOW,
                ACL_PCIE_DMA_WR_CONTROL + sizeof(u32) -
                ACL_PCIE_DMA_RC_WR_DESC_BASE_LOW)))
    return true;
  if (cmd->bar_id == ACL_PCI_CRA_BAR &&
      (overlaps(offset, size, PCIE_CRA_IRQ_ENABLE, sizeof(u32)) ||
       overlaps(offset, size, PCIE_CRA_IRQ_STATUS, sizeof(u32))))
    return true;
  if (cmd->bar_id == ACL_PRCONTROLLER_BAR &&
      overlaps(offset, size, ACL_PRCONTROLLER_OFFSET, sizeof(u32)))
    return true;
  return cmd->bar_id == ACL_UNIPHYRESET_BAR &&
         overlaps(offset, size, ACL_UNIPHYRESET_OFFSET, sizeof(u32));
}

/* High-level read/write dispatcher. */
static ssize_t aclpci_rw(struct file *file, char __user *buf,
                  size_t count, loff_t *pos,
                  int reading) {
  
  struct aclpci_file *owner = file->private_data;
  struct aclpci_dev *aclpci = owner ? owner->aclpci : NULL;
  struct acl_cmd __user *ucmd;
  struct acl_cmd kcmd;
  u64 old_segment = 0;
  u64 memory_bytes;
  int restore_segment = 0;
  void *addr = 0;
  int access_le = 0;
  int aligned = 0;
  int use_dma = 0;
  ssize_t result = 0;
  ssize_t errno = 0;
  size_t size = 0;

  if (!aclpci)
    return -ENODEV;
  if (down_interruptible(&aclpci->sem))
    return -ERESTARTSYS;
  if (!aclpci->online || aclpci->removed || owner->closed) {
    result = -ENODEV;
    goto done;
  }

  ucmd = (struct acl_cmd __user *) buf;
  if (copy_from_user (&kcmd, ucmd, sizeof(*ucmd))) {
		result = -EFAULT;
    goto done;
	}

  /* A competing handle cannot issue lifecycle commands such as DMA_STOP. */
  if (aclpci->control_owner && aclpci->control_owner != owner) {
    result = -EBUSY;
    goto done;
  }
  size = kcmd.size;
  if (kcmd.bar_id == ACLPCI_CMD_BAR) {
    /* The legacy payload-setting case is outside the supplied excerpts.
     * Keep it intact, but exclude IRQ snapshots while it updates the pair. */
    bool sync_irq = (kcmd.command == ACLPCI_CMD_SET_SIGNAL_PAYLOAD ||
                     kcmd.command == ACLPCI_CMD_ENABLE_KERNEL_IRQ) &&
                    aclpci->irq_registered;

    if (sync_irq)
      disable_irq(aclpci->irq_number);
    result = aclpci_exec_cmd(aclpci, kcmd, size);
    if (!result && (kcmd.command == ACLPCI_CMD_SET_SIGNAL_PAYLOAD ||
                    kcmd.command == ACLPCI_CMD_ENABLE_KERNEL_IRQ))
      aclpci_set_signal_task(aclpci, current);
    if (sync_irq)
      enable_irq(aclpci->irq_number);
    goto done;
  }
  if (aclpci->io_blocked || !READ_ONCE(aclpci->dma_data.contract_valid)) {
    result = -EOPNOTSUPP;
    goto done;
  }
  /* Linux size_t/ssize_t have the same width; reject signed-return overflow. */
  if (size > (SIZE_MAX >> 1)) {
    result = -EOVERFLOW;
    goto done;
  }
  if (!size)
    goto done;
  mutex_lock(&aclpci->dma_data.lock);
  memory_bytes = aclpci->dma_data.device_memory_bytes;
  mutex_unlock(&aclpci->dma_data.lock);
  if (kcmd.bar_id == ACLPCI_DMA_BAR &&
      (!memory_bytes || (u64)(unsigned long)kcmd.device_addr > memory_bytes ||
       size > memory_bytes - (u64)(unsigned long)kcmd.device_addr)) {
    result = -ERANGE;
    goto done;
  }
  if (!reading && protected_write(&kcmd, size)) {
    result = -EPERM;
    goto done;
  }
  /* No raw access, segment change or PR may race an owned table. A second
   * DMA also receives EBUSY; the asynchronous owner is never replaced. */
  if (aclpci_dma_busy(aclpci)) {
    result = -EBUSY;
    goto done;
  }
  aclpci_set_signal_task(aclpci, current);

  /* If access_le is true, it explicitly shows that we want to interpret the target memory as 
   * little-endian. Otherwise, the same endianess as the host will be used. 
   */
  access_le = !kcmd.is_diff_endian;
  
  /* Only using DMA for large aligned reads/writes on global memory
   * (due to some assumptions inside the DMA hardware). */
  aligned = aligned_request (&kcmd, size);
  use_dma = USE_DMA && (size >= 1024) && 
            aligned && kcmd.bar_id == ACLPCI_DMA_BAR;
  ACL_VERBOSE_DEBUG (KERN_DEBUG "\n\n-----------------------");
  ACL_VERBOSE_DEBUG (KERN_DEBUG " kcmd = {%u, %p, %p}, count = %lu", 
             kcmd.bar_id, (void*)kcmd.device_addr, (void*)kcmd.user_addr, size);

  if (!use_dma) {
    /* Global-memory aperture was checked before choosing DMA versus PIO. */
    if (kcmd.bar_id != ACLPCI_DMA_BAR) {
      addr = aclpci_get_checked_addr (kcmd.bar_id, kcmd.device_addr, size, aclpci, &errno, 0);
    }
    else {
      /* If not using DMA, but command specifies addresses in DMA's address
       * space, we need to translate these to accesses to the memwindow.  The
       * user-space written HAL currently also does this so we need to restore
       * the current segment in hardware. */

      ACL_VERBOSE_DEBUG (KERN_DEBUG "For global memory accesses, trying to change segment so the address is mapped into PCIe BAR");
      if (size > ACL_PCIE_MEMWINDOW_SIZE -
          ((unsigned long)kcmd.device_addr % ACL_PCIE_MEMWINDOW_SIZE)) {
        result = -ERANGE;
        goto done;
      }
      if (!aclpci->global_mem_segment_valid) {
        aclpci->global_mem_segment = readq(aclpci->global_mem_segment_addr);
        aclpci->global_mem_segment_valid = true;
      }
      old_segment = aclpci->global_mem_segment;
      restore_segment = 1;
      kcmd.bar_id = ACL_PCIE_MEMWINDOW_BAR;
      kcmd.device_addr = aclpci_set_segment (aclpci, kcmd.device_addr);
      addr = aclpci_get_checked_addr (kcmd.bar_id, kcmd.device_addr, size, aclpci, &errno, 1);
    }

    if (errno != 0) {
      result = -EFAULT;
      goto done;
    }
  }


  /* Raw BAR access to the memory window must obey the same image aperture.
   * A window access may not straddle into control registers. Read the actual
   * segment if its shadow has not yet been established. */
  if (kcmd.bar_id == ACL_PCIE_MEMWINDOW_BAR &&
      overlaps((unsigned long)kcmd.device_addr, size,
               ACL_PCIE_MEMWINDOW_BASE, ACL_PCIE_MEMWINDOW_SIZE)) {
    u64 offset = (unsigned long)kcmd.device_addr;
    u64 segment;
    if (offset < ACL_PCIE_MEMWINDOW_BASE ||
        offset - ACL_PCIE_MEMWINDOW_BASE >= ACL_PCIE_MEMWINDOW_SIZE ||
        size > ACL_PCIE_MEMWINDOW_SIZE - (offset - ACL_PCIE_MEMWINDOW_BASE) ||
        !memory_bytes) {
      result = -ERANGE;
      goto done;
    }
    if (!aclpci->global_mem_segment_valid) {
      aclpci->global_mem_segment = readq(aclpci->global_mem_segment_addr);
      aclpci->global_mem_segment_valid = true;
    }
    segment = aclpci->global_mem_segment;
    offset -= ACL_PCIE_MEMWINDOW_BASE;
    if (segment % ACL_PCIE_MEMWINDOW_SIZE || segment > memory_bytes ||
        offset > memory_bytes - segment ||
        size > memory_bytes - segment - offset) {
      result = -ERANGE;
      goto done;
    }
  }


  /* Segment writes have one user copy, one hardware write, and then a
   * shadow update. Refuse partial/overlapping writes that bypass the shadow. */
  if (!reading && kcmd.bar_id == ACL_PCIE_MEMWINDOW_BAR &&
      overlaps((unsigned long)kcmd.device_addr, size,
               ACL_PCIE_MEMWINDOW_CRA, sizeof(u64))) {
    u64 segment, checked_segment;

    if (addr != aclpci->global_mem_segment_addr || size != sizeof(segment)) {
      result = -EINVAL;
      goto done;
    }
    if (copy_from_user(&segment, kcmd.user_addr, sizeof(segment))) {
      result = -EFAULT;
      goto done;
    }
    /* In either access mode the register consumes a little-endian value. */
    checked_segment = access_le ? segment : le64_to_cpu((__le64)segment);
    if (!memory_bytes || checked_segment >= memory_bytes ||
        checked_segment % ACL_PCIE_MEMWINDOW_SIZE) {
      result = -ERANGE;
      goto done;
    }
    if (access_le) {
      writeq(segment, addr);
    } else {
      __raw_writel(((u32 *)&segment)[0], addr);
      mb();
      __raw_writel(((u32 *)&segment)[1], (u8 *)addr + sizeof(u32));
      segment = checked_segment;
    }
    aclpci->global_mem_segment = segment;
    aclpci->global_mem_segment_valid = true;
    goto done;
  }

  /* Offset value is always an address offset, not element offset. */
  /* ACL_DEBUG (KERN_DEBUG "Read address is %p", addr); */
  
  switch (size) {
  case 1:
  case 2:
  case 4:
  case 8: {
    if (reading) {
      result = aclpci_read_small  (addr, (void __user*) kcmd.user_addr, size, access_le);
    } else {
      result = aclpci_write_small (addr, (void __user*) kcmd.user_addr, size, access_le);
    }
    break;
  }
    
  default:
    if (use_dma) {
      result = aclpci_dma_rw (aclpci, owner, kcmd.device_addr, (void __user*) kcmd.user_addr, size, reading);
    } else {
      result = aclpci_rw_large (addr, (void __user*) kcmd.user_addr, size, aclpci->buffer, reading, access_le );
    }
    break;
  }
  
done:
  /* Restore on failures as well as successful PIO. */
  if (restore_segment) {
    ACL_VERBOSE_DEBUG (KERN_DEBUG "Restoring mem segment to %llu", old_segment);
    aclpci_set_segment_by_val (aclpci, old_segment);
  }
  
  up (&aclpci->sem);
  return result;
}


/* Response to user's read() call */
ssize_t aclpci_read(struct file *file, char __user *buf, 
                    size_t count, loff_t *pos) {
  return aclpci_rw (file, buf, count, pos, 1 /* reading */);
}


/* Response to user's write() call */
ssize_t aclpci_write(struct file *file, const char __user *buf, 
                     size_t count, loff_t *pos) {
  return aclpci_rw (file, (char __user *)buf, count, pos, 0 /* writing */);
}

