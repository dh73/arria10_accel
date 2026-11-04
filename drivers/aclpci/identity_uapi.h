/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_IDENTITY_UAPI_H
#define ACLPCI_IDENTITY_UAPI_H
/* Read-only native-endian acl_cmd. Exact 68-u32 payload, no pointers inside.
 * Input: version=1 followed by 67 zeros; device_addr=NULL, is_diff_endian=0.
 * Output: version, zero, sequence-before, 64 identity words, sequence-after.
 * One bounded capture of the fixed BAR2 identity region, with temporary
 * exclusive control custody if this file does not already hold it. No retry.
 * No write to hardware, startup, DMA admission or source/image qualification.
 * Capture failure returns an error without copying partial data to userspace.
 * Success means stable self-reported bytes; validate against trusted expected
 * image/source/context and BAR resources before interpreting capabilities. */
#define ACLPCI_CMD_IDENTITY_SNAPSHOT 23
#define ACLPCI_IDENTITY_UAPI_VERSION 1
#define ACLPCI_IDENTITY_UAPI_WORDS 68
#endif
