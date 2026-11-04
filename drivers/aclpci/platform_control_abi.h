/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_PLATFORM_CONTROL_ABI_H
#define ACLPCI_PLATFORM_CONTROL_ABI_H
/* Candidate supervised shell ABI, not a discovery or admission certificate.
 * These control writes belong to kernel lifecycle ownership. Raw userspace
 * access must not acknowledge drain or reopen hardware admission. */
#define ACLPCI_PLATFORM_CONTROL_BAR 2
#define ACLPCI_PLATFORM_IDENTITY_BASE 256
#define ACLPCI_PLATFORM_FENCE_BASE 512
#define ACLPCI_PLATFORM_FENCE_BYTES 40
#define ACLPCI_PLATFORM_COMMAND_BASE 576
#define ACLPCI_PLATFORM_COMMAND_BYTES 32
#define ACLPCI_PLATFORM_CONTEXT_BASE 768
#define ACLPCI_PLATFORM_CONTEXT_BYTES 32
#endif
