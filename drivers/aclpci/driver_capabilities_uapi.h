/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_DRIVER_CAPABILITIES_UAPI_H
#define ACLPCI_DRIVER_CAPABILITIES_UAPI_H
/* Read-only software ABI query, not a board/image/health qualification.
 * Native acl_cmd, device_addr=NULL, native endianness, exact four-u32 payload.
 * Input [version=1,0,0,0]. Output [version,flags,DMA alignment,receipt version].
 * Does not perform MMIO, allocate resources, claim custody or enable DMA. */
#define ACLPCI_CMD_DRIVER_CAPABILITIES 24
#define ACLPCI_DRIVER_CAPABILITIES_VERSION 1
#define ACLPCI_DRIVER_CAPABILITIES_WORDS 4
#define ACLPCI_DRIVER_CAP_EVENT_ONLY_DMA 1
#define ACLPCI_DRIVER_CAP_EXACT_RECEIPT 2
#define ACLPCI_DRIVER_CAP_IDENTITY_SNAPSHOT 4
#endif
