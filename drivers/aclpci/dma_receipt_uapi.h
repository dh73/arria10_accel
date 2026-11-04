/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_DMA_RECEIPT_UAPI_H
#define ACLPCI_DMA_RECEIPT_UAPI_H
/* Read-only command, eight native-endian u32 words, exact size.
 * Input: version, zero, expected generation low/high, four zero words.
 * Expected zero snapshots the counter; it is NOT a completion certificate.
 * Output: version, state, submitted low/high, completed low/high, signed result,
 * zero. States: NONE=0, PENDING=1, DRAINED=2. Nonzero expected must match the
 * latest submitted generation, or ESTALE is returned without copyout.
 * Serialize submission/query on this file. Snapshot before submission and use
 * the next generation after acceptance; unknown submission must never replay.
 * DRAINED is published after mapping release, not on IRQ or idle observation.
 * The receipt covers request buffers, not destruction of shared DMA tables.
 * Request generations never wrap and are scoped to the open file lifetime. */
#define ACLPCI_CMD_DMA_RECEIPT 21
#define ACLPCI_DMA_RECEIPT_VERSION 1
#define ACLPCI_DMA_RECEIPT_WORDS 8
#define ACLPCI_DMA_RECEIPT_NONE 0
#define ACLPCI_DMA_RECEIPT_PENDING 1
#define ACLPCI_DMA_RECEIPT_DRAINED 2
#endif
