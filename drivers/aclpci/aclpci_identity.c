/* SPDX-License-Identifier: BSD-3-Clause */
#include "aclpci_identity.h"
#ifdef __KERNEL__
#include <linux/string.h>
#else
#include <string.h>
#endif
enum aclpci_identity_code aclpci_identity_capture(
    int (*read)(void *, unsigned int, aclpci_id_u32 *), void *context,
    struct aclpci_identity_raw *raw)
{
    const aclpci_id_u32 prefix[6] = {ACLPCI_ID_MAGIC, ACLPCI_ID_V1, 1,
        ACLPCI_ID_BYTES, ACLPCI_ID_CAPABILITIES, ACLPCI_ID_CAPABILITIES};
    aclpci_id_u32 value = 0, version = 0;
    unsigned int i;
    if (!raw) return ACLPCI_ID_INVALID;
    memset(raw, 0, sizeof(*raw));
    if (!read) return ACLPCI_ID_IO_FAILURE;
    for (i = 0; i < 6; ++i) {
        if (read(context, 4*i, &value)) return ACLPCI_ID_IO_FAILURE;
        if (i == 1) {
            if (value != ACLPCI_ID_V1 && value != ACLPCI_ID_V2) return ACLPCI_ID_UNSUPPORTED;
            version = value;
        } else if (value != (i == 2 ? version >> 16 : prefix[i]))
            return ACLPCI_ID_UNSUPPORTED;
    }
    if (read(context, 24, &raw->before)) return ACLPCI_ID_IO_FAILURE;
    if (!raw->before) return ACLPCI_ID_INVALID;
    for (i = 0; i < ACLPCI_ID_WORDS; ++i)
        if (read(context, 4*i, &raw->words[i])) return ACLPCI_ID_IO_FAILURE;
    if (read(context, 24, &raw->after)) return ACLPCI_ID_IO_FAILURE;
    return raw->before == raw->after && raw->before == raw->words[6]
        ? ACLPCI_ID_CONSISTENT : ACLPCI_ID_TORN;
}

static aclpci_id_u64 word64(const struct aclpci_identity_raw *r, unsigned int n)
{
    return r->words[n] | ((aclpci_id_u64)r->words[n + 1] << 32);
}
static int nonzero(const void *p, unsigned int bytes)
{
    const aclpci_id_u8 *b = p;
    unsigned int i;
    for (i = 0; i < bytes; ++i) if (b[i]) return 1;
    return 0;
}
static void digest(aclpci_id_u8 out[32], const struct aclpci_identity_raw *r,
                   unsigned int start)
{
    unsigned int i;
    for (i = 0; i < 32; ++i)
        out[i] = (aclpci_id_u8)(r->words[start + i / 4] >> ((i % 4) * 8));
}
static int in_resource(struct aclpci_identity_range r, unsigned int align,
                        const struct aclpci_identity_resource *v, unsigned int n)
{
    unsigned int i;
    if (!r.bytes || r.offset % align || r.bytes % align) return 0;
    for (i = 0; i < n; ++i)
        if (v[i].space == r.space)
            return r.offset <= v[i].bytes && r.bytes <= v[i].bytes - r.offset;
    return 0;
}
static int ranges(struct aclpci_identity_range a, struct aclpci_identity_range b,
                   aclpci_id_u32 cra_bytes, const struct aclpci_identity_resource *v,
                   unsigned int n)
{
    unsigned int i, j;
    for (i = 0; i < n; ++i) {
        if (!v[i].bytes) return 0;
        for (j = 0; j < i; ++j) if (v[j].space == v[i].space) return 0;
    }
    if (a.bytes != ACLPCI_ID_BYTES || b.bytes != cra_bytes ||
        !in_resource(a, 4, v, n) || !in_resource(b, 8, v, n)) return 0;
    /* in_resource established representable endpoints. */
    return a.space != b.space || a.offset + a.bytes <= b.offset ||
           b.offset + b.bytes <= a.offset;
}
static int equal_range(struct aclpci_identity_range a, struct aclpci_identity_range b)
{
    return a.space == b.space && a.offset == b.offset && a.bytes == b.bytes;
}
enum aclpci_identity_code aclpci_identity_check(
    const struct aclpci_identity_raw *r, const struct aclpci_identity_expected *e,
    const struct aclpci_identity_resource *v, unsigned int n,
    struct aclpci_identity_observation *o)
{
    const aclpci_id_u32 *w;
    struct aclpci_identity_health *h;
    unsigned int i;
    if (!o) return ACLPCI_ID_INVALID;
    memset(o, 0, sizeof(*o));
    if (!r || !e || (n && !v)) return ACLPCI_ID_INVALID;
    w = r->words;
    if (!r->before || !r->after || w[7] != 1) return ACLPCI_ID_INVALID;
    if (r->before != r->after || r->before != w[6]) return ACLPCI_ID_TORN;
    if (w[0] != ACLPCI_ID_MAGIC ||
        !((w[1] == ACLPCI_ID_V1 && w[2] == 1) ||
          (w[1] == ACLPCI_ID_V2 && w[2] == 2)) ||
        w[3] != ACLPCI_ID_BYTES || w[4] != ACLPCI_ID_CAPABILITIES ||
        w[5] != ACLPCI_ID_CAPABILITIES) return ACLPCI_ID_UNSUPPORTED;
    for (i = 43; i < ACLPCI_ID_WORDS; ++i)
        if (w[i]) return ACLPCI_ID_MALFORMED;
    if ((w[38] & ~0x7ffu) || (w[40] & 0xfe000000u) ||
        (w[42] & ~(w[2] == 2 ? ACLPCI_ID_V2_ADDRESS_HIGH_MASK :
                              ACLPCI_ID_V1_ADDRESS_HIGH_MASK)))
        return ACLPCI_ID_MALFORMED;
    if (!(w[40] & (1u << 24)) && word64(r, 41)) return ACLPCI_ID_MALFORMED;
    if (!(w[38] & 1u)) {
        for (i = 38; i < 43; ++i) if (w[i]) return ACLPCI_ID_MALFORMED;
    } else if (((w[38] >> 1) & 7) > 6 || ((w[38] >> 4) & 7) > 5)
        return ACLPCI_ID_MALFORMED;
    o->sequence = r->before;
    digest(o->source, r, 8); digest(o->build, r, 16);
    o->management.space = w[24]; o->management.offset = word64(r, 26);
    o->management.bytes = ACLPCI_ID_BYTES;
    o->cra.space = w[25]; o->cra.offset = word64(r, 28); o->cra.bytes = word64(r, 30);
    for (i = 0; i < 4; ++i) o->context.session[i] = w[32 + i];
    o->context.epoch = word64(r, 36);
    if (!nonzero(o->source, 32) || !nonzero(o->build, 32)) return ACLPCI_ID_MALFORMED;
    if (!nonzero(e->context.session, sizeof(e->context.session)) || !e->context.epoch ||
        memcmp(o->context.session, e->context.session, sizeof(e->context.session)) ||
        o->context.epoch != e->context.epoch) return ACLPCI_ID_STALE_CONTEXT;
    if (!ranges(e->management, e->cra, e->aperture_bytes, v, n) ||
        !ranges(o->management, o->cra, e->aperture_bytes, v, n)) return ACLPCI_ID_BAD_RANGE;
    if (!equal_range(o->management, e->management) || !equal_range(o->cra, e->cra))
        return ACLPCI_ID_MAPPING_MISMATCH;
    if (memcmp(o->source, e->source, 32)) return ACLPCI_ID_SOURCE_MISMATCH;
    if (memcmp(o->build, e->build, 32)) return ACLPCI_ID_BUILD_MISMATCH;
    h = &o->health;
    h->valid = !!(w[38] & 1); h->state = (w[38] >> 1) & 7; h->phase = (w[38] >> 4) & 7;
    h->fault = !!(w[38] & 128); h->release_ready = !!(w[38] & 256);
    h->launch_permit = !!(w[38] & 512); h->host_submit_permit = !!(w[38] & 1024);
    h->history = (aclpci_id_u16)w[39]; h->pending = (aclpci_id_u16)(w[39] >> 16);
    h->first_code = (aclpci_id_u16)w[40]; h->adapter_code = (aclpci_id_u8)(w[40] >> 16);
    h->address_valid = !!(w[40] & (1u << 24)); h->address = word64(r, 41);
    return e->source_reextracted ? ACLPCI_ID_CONSISTENT : ACLPCI_ID_TEST_SOURCE_ONLY;
}
