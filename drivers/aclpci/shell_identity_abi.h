/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_SHELL_IDENTITY_ABI_H
#define ACLPCI_SHELL_IDENTITY_ABI_H
/* Existing read-only identity wire layout; no physical mapping or admission. */
#define ACLPCI_ID_MAGIC 0x31444941u
#define ACLPCI_ID_V1 0x00010000u
#define ACLPCI_ID_V2 0x00020000u
#define ACLPCI_ID_BYTES 256u
#define ACLPCI_ID_WORDS 64u
#define ACLPCI_ID_CAPABILITIES 31u
#define ACLPCI_ID_V1_ADDRESS_HIGH_MASK 7u
#define ACLPCI_ID_V2_ADDRESS_HIGH_MASK 0x1ffu
#endif
