/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_STARTUP_UAPI_H
#define ACLPCI_STARTUP_UAPI_H
/* Native acl_cmd transport, command BAR. Payload is ten native-endian u32
 * words, without pointers or ABI-dependent padding. No DMA admission implied.
 * ARM: write only, version=1, operation=1, context[6], id low/high.
 * STEP: read only, version=1, operation=2, remaining words zero.
 * ARM returns 0 after staging only; STEP returns 0 pending, 1 accepted,
 * 2 rejected, negative permanent error. Never replay ARM after uncertain I/O.
 * Issued control debt survives errors and close; STEP never releases custody. */
#define ACLPCI_CMD_STARTUP 20
#define ACLPCI_STARTUP_UAPI_WORDS 10
#define ACLPCI_STARTUP_UAPI_VERSION 1
#define ACLPCI_STARTUP_UAPI_ARM 1
#define ACLPCI_STARTUP_UAPI_STEP 2
#endif
