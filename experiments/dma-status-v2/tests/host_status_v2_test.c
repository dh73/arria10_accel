/* SPDX-License-Identifier: BSD-3-Clause */
#include <assert.h>
#include <stdio.h>
#include "../host/aclpci_dma_status_v2.h"
#include "../host/aclpci_dma_request.h"
#include <linux/errno.h>
unsigned int aclpci_user_dma_segments(struct aclpci_user_dma *m) { return m->segments; }
bool aclpci_user_dma_matches_direction(struct aclpci_user_dma *m, bool d) { return m->direction == d; }
void aclpci_user_dma_release(struct aclpci_user_dma *m, bool written) {
    assert(written == m->direction); m->releases++;
}
int aclpci_dma_build_batch(struct aclpci_user_dma *m,
    const struct aclpci_batch_cursor *c, unsigned int id, bool d,
    struct aclpci_batch_descriptor *table, unsigned int *count,
    struct aclpci_batch_cursor *pending) {
    (void)id; (void)d; (void)table;
    *pending = *c; pending->segment = m->segments; *count = 2; return 0;
}
typedef uint32_t u32;
struct fake_dma_table { struct { u32 flags[128]; } header; };
struct aclpci_dma {
    struct aclpci_dma_request request;
    bool active, contract_valid;
    int fault, last_id[2];
    struct fake_dma_table *tables[2];
    u64 ticket;
};
static unsigned int barrier_count;
#define READ_ONCE(value) (value)
#define WRITE_ONCE(value, new_value) ((value) = (new_value))
#define le32_to_cpu(value) (value)
static void dma_rmb(void) { barrier_count++; }
#include "../host/harvest_locked_v2.inc"

static void test_harvest_flags(bool qualified, u32 flag, u32 earlier, int expected)
{
    struct aclpci_user_dma mapping = {1, true, 0};
    struct aclpci_batch_descriptor batch;
    struct fake_dma_table table = {0};
    struct aclpci_dma dma = {0};
    dma.active = true;
    dma.contract_valid = qualified;
    dma.tables[1] = &table;
    dma.last_id[1] = 8;
    assert(aclpci_dma_request_init(&dma.request, &mapping, 0x2000, 7, true) == 0);
    assert(aclpci_dma_request_build(&dma.request, &batch) == 0);
    assert(aclpci_dma_request_submit(&dma.request, &dma.ticket) == 0);
    table.header.flags[7] = earlier;
    table.header.flags[8] = flag;
    barrier_count = 0;
    assert(harvest_locked(&dma) == expected);
    if (expected == 1) {
        assert(barrier_count == 1);
        assert(dma.request.phase == ACLPCI_REQUEST_TERMINAL);
        assert(aclpci_dma_request_release(&dma.request) == 0);
    } else if (expected < 0) {
        assert(!dma.contract_valid && barrier_count == 0);
        assert(dma.request.phase == ACLPCI_REQUEST_IN_FLIGHT);
        assert(aclpci_dma_request_release(&dma.request) == -EBUSY);
        table.header.flags[8] = 1;
        assert(harvest_locked(&dma) == expected && barrier_count == 0);
        assert(aclpci_dma_request_retire(&dma.request, dma.ticket) == expected);
    } else {
        assert(dma.request.phase == ACLPCI_REQUEST_IN_FLIGHT && !barrier_count);
    }
}
static void test_harvest(bool qualified, u32 flag, int expected)
{
    test_harvest_flags(qualified, flag, 0, expected);
}
int main(void)
{
    struct aclpci_status_fields_v2 decoded, old_owner, new_owner;
    struct aclpci_dma_request request;
    struct aclpci_user_dma mapping = {1, true, 0};
    struct aclpci_batch_descriptor table;
    u64 ticket;
    /* Original error0 is pending, never a success. Only exact1 qualifies. */
    assert(aclpci_dma_host_status_v2(0, 7, false, NULL) == ACLPCI_HOST_PENDING);
    assert(aclpci_dma_host_status_v2(1, 7, false, NULL) == ACLPCI_HOST_UNQUALIFIED);
    assert(aclpci_dma_host_status_v2(1, 7, true, NULL) == ACLPCI_HOST_SUCCESS);
    assert(aclpci_dma_status_v2_decode(0x20010d07u, &decoded) == ACLPCI_WIRE_SUCCESS);
    assert(decoded.id == 7 && decoded.generation == 1 && decoded.slot == 0);
    assert(aclpci_dma_host_status_v2(0x20010d07u, 7, true, NULL) == ACLPCI_HOST_MALFORMED);
    /* Master-disabled ID7 with and without local retirement retains mapping. */
    assert(aclpci_dma_host_status_v2(0x21010607u, 7, true, NULL) == ACLPCI_HOST_RETAIN_ERROR);
    assert(aclpci_dma_host_status_v2(0x21010e07u, 7, true, NULL) == ACLPCI_HOST_RETAIN_ERROR);
    assert(aclpci_dma_host_status_v2(0x22010007u, 7, true, NULL) == ACLPCI_HOST_RETAIN_NONTERMINAL);
    assert(aclpci_dma_host_status_v2(0x2f01f607u, 7, true, NULL) == ACLPCI_HOST_RETAIN_ERROR);
    assert(aclpci_dma_host_status_v2(0x21010600u, 7, true, NULL) == ACLPCI_HOST_MALFORMED);
    assert(aclpci_dma_host_status_v2(0x21010687u, 7, true, NULL) == ACLPCI_HOST_MALFORMED);
    assert(aclpci_dma_host_status_v2(1u, 128, true, NULL) == ACLPCI_HOST_MALFORMED);
    assert(aclpci_dma_status_v2_decode(0x21000607u, NULL) == ACLPCI_WIRE_INVALID);
    assert(aclpci_dma_status_v2_decode(0x31010607u, NULL) == ACLPCI_WIRE_INVALID);
    assert(aclpci_dma_status_v2_decode(0x21010707u, NULL) == ACLPCI_WIRE_INVALID);
    assert(aclpci_dma_status_v2_decode(0x22010607u, NULL) == ACLPCI_WIRE_INVALID);
    assert(aclpci_dma_status_v2_decode(0x20010507u, NULL) == ACLPCI_WIRE_INVALID);
    assert(aclpci_dma_status_v2_decode(0x20011d87u, &decoded) == ACLPCI_WIRE_SUCCESS);
    assert(decoded.id == 135 && decoded.slot == 1);
    old_owner = decoded; new_owner = decoded; new_owner.generation++;
    assert(!aclpci_dma_status_v2_same_owner(&old_owner, &new_owner));
    assert(aclpci_dma_status_v2_same_owner(&old_owner, &decoded));

    assert(aclpci_dma_request_init(&request, &mapping, 0x2000, 7, true) == 0);
    assert(aclpci_dma_request_build(&request, &table) == 0);
    assert(aclpci_dma_request_submit(&request, &ticket) == 0);
    assert(aclpci_dma_request_latch_error(&request, ticket + 1, -EIO) == -ESTALE);
    assert(!request.fault_latched);
    assert(aclpci_dma_request_latch_error(&request, ticket, -EIO) == 0);
    aclpci_dma_request_stop(&request);
    assert(request.phase == ACLPCI_REQUEST_IN_FLIGHT && request.mapping == &mapping);
    assert(aclpci_dma_request_release(&request) == -EBUSY && mapping.releases == 0);
    /* A later apparently successful flag must not repair poisoned ownership. */
    assert(aclpci_dma_request_retire(&request, ticket) == -EIO);
    assert(request.phase == ACLPCI_REQUEST_IN_FLIGHT);
    assert(aclpci_dma_request_latch_error(&request, ticket, -ECANCELED) == 0);
    assert(request.result == -EIO);
    assert(aclpci_dma_request_confirm_fault_retirement(&request, ticket + 1) == -ESTALE);
    /* This explicit test call models an independent external retirement proof;
     * it does not assert that any RTL/PCIe/hardware path supplied one. */
    assert(aclpci_dma_request_confirm_fault_retirement(&request, ticket) == 0);
    assert(request.cursor.segment == 0 && request.result == -EIO);
    assert(aclpci_dma_request_release(&request) == 0 && mapping.releases == 1);
    assert(request.mapping == NULL);
    test_harvest(false, 0, 0);
    test_harvest(false, 1, -EOPNOTSUPP);
    test_harvest(true, 1, 1);
    test_harvest(true, 0x21010608u, -EIO);
    test_harvest(true, 0x21010e08u, -EIO);
    test_harvest(true, 0x22010008u, -EIO);
    test_harvest(true, 0x21010607u, -EIO);
    test_harvest_flags(true, 0, 0x21010607u, -EIO);
    test_harvest_flags(true, 1, 0x21010607u, -EIO);
    test_harvest_flags(true, 0, 1, 0);
    puts("PASS host v2 decoder, request retention, and harvest barrier regression");
    return 0;
}
