/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_IDENTITY_H
#define ACLPCI_IDENTITY_H
#include "shell_identity_abi.h"
#ifdef __KERNEL__
#include <linux/types.h>
typedef u8 aclpci_id_u8;
typedef u16 aclpci_id_u16;
typedef u32 aclpci_id_u32;
typedef u64 aclpci_id_u64;
#else
#include <stdint.h>
typedef uint8_t aclpci_id_u8;
typedef uint16_t aclpci_id_u16;
typedef uint32_t aclpci_id_u32;
typedef uint64_t aclpci_id_u64;
#endif
#ifdef __cplusplus
extern "C" {
#endif
/* Values match the existing host Code enum; these are not an ioctl ABI. */
enum aclpci_identity_code {
    ACLPCI_ID_CONSISTENT, ACLPCI_ID_TEST_SOURCE_ONLY, ACLPCI_ID_IO_FAILURE,
    ACLPCI_ID_REPLY_MISMATCH, ACLPCI_ID_CURSOR_CLOSED, ACLPCI_ID_TORN,
    ACLPCI_ID_INVALID, ACLPCI_ID_UNSUPPORTED, ACLPCI_ID_MALFORMED,
    ACLPCI_ID_BAD_RANGE, ACLPCI_ID_MAPPING_MISMATCH, ACLPCI_ID_STALE_CONTEXT,
    ACLPCI_ID_SOURCE_MISMATCH, ACLPCI_ID_BUILD_MISMATCH
};
struct aclpci_identity_raw {
    aclpci_id_u32 before, words[ACLPCI_ID_WORDS], after;
};
struct aclpci_identity_range { aclpci_id_u32 space; aclpci_id_u64 offset, bytes; };
struct aclpci_identity_resource { aclpci_id_u32 space; aclpci_id_u64 bytes; };
struct aclpci_identity_context { aclpci_id_u32 session[4]; aclpci_id_u64 epoch; };
struct aclpci_identity_expected {
    aclpci_id_u8 source[32], build[32];
    struct aclpci_identity_range management, cra;
    struct aclpci_identity_context context;
    aclpci_id_u32 aperture_bytes;
    /* Provenance supplied by the trusted caller, never decoded from hardware.
     * True means source re-extraction only, not a qualified physical image. */
    unsigned int source_reextracted;
};
struct aclpci_identity_health {
    unsigned int valid, fault, release_ready, launch_permit, host_submit_permit;
    aclpci_id_u8 state, phase, adapter_code;
    aclpci_id_u16 history, pending, first_code;
    unsigned int address_valid;
    aclpci_id_u64 address;
};
struct aclpci_identity_observation {
    aclpci_id_u8 source[32], build[32];
    struct aclpci_identity_context context;
    struct aclpci_identity_range management, cra;
    aclpci_id_u32 sequence;
    struct aclpci_identity_health health;
};
/* Pure decode of already captured CPU-endian words. No MMIO, retries, memory
 * allocation, ownership/admission mutation or drain certification. Resources
 * are explicit trusted declarations. Even CONSISTENT is self-reported identity;
 * health readiness/fault flags are diagnostics, not qualification predicates.
 * On failure observation is zero or partial, never an accepted identity. */
enum aclpci_identity_code aclpci_identity_check(
    const struct aclpci_identity_raw *, const struct aclpci_identity_expected *,
    const struct aclpci_identity_resource *, unsigned int resource_count,
    struct aclpci_identity_observation *);
#ifdef __cplusplus
}
#endif
#endif
