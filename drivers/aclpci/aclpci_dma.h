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

#ifndef ACLPCI_DMA_H
#define ACLPCI_DMA_H

#include <linux/mutex.h>
#include <linux/workqueue.h>
#include "aclpci_dma_request.h"

struct aclpci_dev;
struct aclpci_file;

/* Exact historical ABI: 512 status bytes, then 128 32-byte descriptors.
 * Natural alignment is sufficient; packed/volatile do not replace barriers. */
struct dma_desc_header { __le32 flags[128]; };
struct dma_desc_table {
    struct dma_desc_header header;
    struct aclpci_batch_descriptor descriptors[128];
};

struct aclpci_dma {
    struct mutex lock;             /* Never acquire aclpci->sem in a worker. */
    struct work_struct work;
    struct workqueue_struct *wq;
    struct aclpci_dev *aclpci;
    struct dma_desc_table *tables[2]; /* 0: RC read / H2D; 1: RC write / D2H */
    dma_addr_t table_dma[2];
    struct aclpci_dma_request request;
    struct aclpci_file *owner;
    struct task_struct *task;
    struct kernel_siginfo signal;
    u64 ticket;
    int last_id[2];
    int async_result;
    int fault;
    bool initialized;
    bool active;
    /* Deliberately false in production: no shell retirement/removal contract
     * is supplied. No module parameter, PCI ID or user command can set it. */
    bool contract_valid;
};

#endif
