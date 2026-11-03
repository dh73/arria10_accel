"""Fault injection into the actual mapping C source, with mocked kernel APIs.

This exercises ownership/unwind logic, not real GUP, IOMMU or hardware behavior.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MOCK = r'''
#ifndef MOCK_KERNEL_H
#define MOCK_KERNEL_H
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <limits.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
typedef uint64_t dma_addr_t;
enum dma_data_direction { DMA_BIDIRECTIONAL, DMA_TO_DEVICE, DMA_FROM_DEVICE };
struct device { int refs; };
struct page { int id; };
struct mm_struct { int refs; unsigned long charged; } user_mm;
struct task { struct mm_struct *mm; } task = { &user_mm };
#define current (&task)
#define PAGE_SHIFT 12
#define PAGE_SIZE 4096UL
#define PAGE_MASK (~4095UL)
#define offset_in_page(a) ((a) & 4095UL)
#define GFP_KERNEL 0
#define FOLL_LONGTERM 1
#define FOLL_WRITE 2
#define check_add_overflow(a,b,p) __builtin_add_overflow(a,b,p)
#define min_t(t,a,b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
static int alloc_call, alloc_fail, live_alloc, pins, maps, map_call, map_fail;
static int pin_result, dirty, flags_seen;
static int charge_fail;
static size_t max_map;
static struct page pages[4];
static size_t offsets[4], lengths[4];
static enum dma_data_direction dirs[4];
static bool active[4];
static void mmget(struct mm_struct *mm) { assert(mm==&user_mm); ++mm->refs; }
static void mmput(struct mm_struct *mm) {
    assert(mm==&user_mm && mm->refs==1 && !mm->charged && !pins && !maps);
    --mm->refs;
}
static int account_locked_vm(struct mm_struct *mm, unsigned long n, bool inc) {
    assert(mm==&user_mm && mm->refs==1);
    if(inc) {
        assert(!pins && !maps);
        if(charge_fail) return -ENOMEM;
        mm->charged+=n;
    } else {
        assert(!pins && !maps && mm->charged==n); mm->charged-=n;
    }
    return 0;
}
static void *allocate(size_t n) {
    if (++alloc_call == alloc_fail) return NULL;
    void *p = calloc(1,n); assert(p); ++live_alloc; return p;
}
#define kzalloc(n,g) allocate(n)
#define kvmalloc_array(n,s,g) allocate((n)*(s))
static void release(void *p) { if(p) { --live_alloc; free(p); } }
#define kvfree release
#define kfree release
static struct device *get_device(struct device *d) { ++d->refs; return d; }
static void put_device(struct device *d) { --d->refs; }
static int pin_user_pages_fast(unsigned long start, int count, unsigned int flags, struct page **out) {
    assert(start == 0x10000); assert(count <= 4); flags_seen = flags;
    int n = pin_result == INT_MAX ? count : pin_result;
    if (n < 0) return n;
    assert(n <= count);
    for(int i=0; i<n; ++i) { pages[i].id=i; out[i]=&pages[i]; }
    pins += n; return n;
}
static void unpin_user_pages_dirty_lock(struct page **p, unsigned long n, bool written) {
    assert(maps == 0); assert(n == (unsigned long)pins);
    for(unsigned long i=0;i<n;++i) assert(p[i] == &pages[i]);
    pins -= n; dirty = written;
}
static size_t dma_max_mapping_size(struct device *d) { (void)d; return max_map; }
static dma_addr_t dma_map_page(struct device *d, struct page *p, size_t off, size_t n, enum dma_data_direction dir) {
    (void)d; int i=p->id; assert(pins>0); ++map_call;
    if(map_call==map_fail) return UINT64_MAX;
    offsets[i]=off; lengths[i]=n; dirs[i]=dir; active[i]=true; ++maps;
    return (dma_addr_t)i*0x10000; /* first mapping deliberately returns zero */
}
static bool dma_mapping_error(struct device *d, dma_addr_t a) { (void)d; return a==UINT64_MAX; }
static void dma_unmap_page(struct device *d, dma_addr_t a, size_t n, enum dma_data_direction dir) {
    (void)d; unsigned int i=a/0x10000;
    assert(i<4 && active[i] && lengths[i]==n && dirs[i]==dir);
    active[i]=false; --maps;
}
#endif
'''

HARNESS = r'''
#include "aclpci_user_dma.c"
static struct device dev;
static void reset(void) {
    assert(!live_alloc && !pins && !maps && !dev.refs);
    assert(!user_mm.refs && !user_mm.charged);
    alloc_call=alloc_fail=map_call=map_fail=dirty=flags_seen=0;
    pin_result=INT_MAX; max_map=PAGE_SIZE; task.mm=&user_mm; charge_fail=0;
    memset(active,0,sizeof(active));
}
static void clean(void) {
    assert(!live_alloc && !pins && !maps && !dev.refs);
    assert(!user_mm.refs && !user_mm.charged);
}
int main(void) {
    struct aclpci_user_dma *m; dma_addr_t bus; size_t bytes;
    reset(); charge_fail=1;
    assert(aclpci_user_dma_prepare(&dev,0x10003,9000,DMA_FROM_DEVICE,&m)==-ENOMEM);
    assert(!m && !pins && !map_call); clean();
    /* Allocation failures at all three allocations. */
    for(int failure=1;failure<=3;++failure) {
        reset(); alloc_fail=failure; m=(void *)1;
        assert(aclpci_user_dma_prepare(&dev,0x10003,9000,DMA_FROM_DEVICE,&m)==-ENOMEM);
        assert(!m); clean();
    }
    /* Negative/zero/partial GUP; no dirtying before submission. */
    int results[]={-EFAULT,0,1,2};
    for(unsigned int i=0;i<4;++i) {
        reset(); pin_result=results[i];
        assert(aclpci_user_dma_prepare(&dev,0x10003,9000,DMA_FROM_DEVICE,&m)==-EFAULT);
        assert(!m && !dirty); clean();
    }
    /* Failure at every mapping leaves no earlier map or pin. */
    for(int failure=1;failure<=3;++failure) {
        reset(); map_fail=failure;
        assert(aclpci_user_dma_prepare(&dev,0x10003,9000,DMA_FROM_DEVICE,&m)==-EIO);
        assert(!m && !dirty); clean();
    }
    /* Different lengths at both ends, valid address zero, both directions. */
    for(int direction=DMA_TO_DEVICE;direction<=DMA_FROM_DEVICE;++direction) {
        reset();
        assert(!aclpci_user_dma_prepare(&dev,0x10003,9000,direction,&m));
        assert(flags_seen==(FOLL_LONGTERM|(direction==DMA_FROM_DEVICE?FOLL_WRITE:0)));
        assert(aclpci_user_dma_segments(m)==3 && pins==3 && maps==3);
        assert(user_mm.refs==1 && user_mm.charged==3);
        size_t expected[]={4093,4096,811};
        for(unsigned int i=0;i<3;++i) {
            assert(!aclpci_user_dma_segment(m,i,&bus,&bytes));
            assert(bus==i*0x10000 && bytes==expected[i]);
            assert(offsets[i]==(i==0?3:0));
        }
        assert(aclpci_user_dma_segment(m,3,&bus,&bytes)==-EINVAL);
        task.mm=NULL; /* deferred release after submitting task exit */
        aclpci_user_dma_release(m,true);
        assert(dirty==(direction==DMA_FROM_DEVICE)); clean();
    }
    reset(); max_map=4094; /* first map succeeds, second is too large */
    assert(aclpci_user_dma_prepare(&dev,0x10003,9000,DMA_FROM_DEVICE,&m)==-E2BIG);
    assert(!m && !dirty); clean();
    reset();
    assert(aclpci_user_dma_prepare(&dev,ULONG_MAX-1,4,DMA_TO_DEVICE,&m)==-EOVERFLOW);
    assert(aclpci_user_dma_prepare(&dev,0x10000,0,DMA_TO_DEVICE,&m)==-EINVAL);
    assert(aclpci_user_dma_prepare(&dev,0x10000,4,DMA_BIDIRECTIONAL,&m)==-EINVAL);
    task.mm=NULL;
    assert(aclpci_user_dma_prepare(&dev,0x10000,4,DMA_TO_DEVICE,&m)==-EINVAL);
    clean(); puts("USER_DMA_FAULT_INJECTION_PASS"); return 0;
}
'''


class UserDmaTest(unittest.TestCase):
    def test_actual_c_ownership_and_failure_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work/'linux').mkdir()
            (work/'linux/sched').mkdir()
            (work/'linux/sched/mm.h').write_text('#include "mock.h"\n')
            (work/'mock.h').write_text(MOCK)
            for name in ('device', 'err', 'limits', 'mm', 'overflow', 'sched',
                         'slab', 'vmalloc', 'dma-mapping'):
                (work/'linux'/f'{name}.h').write_text('#include "mock.h"\n')
            (work/'test.c').write_text(HARNESS)
            binary = work/'test'
            subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                            '-I'+str(work),
                            '-I'+str(ROOT/'drivers/aclpci'), str(work/'test.c'),
                            '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], check=True, text=True, capture_output=True)
            self.assertEqual(result.stdout.strip(), 'USER_DMA_FAULT_INJECTION_PASS')


if __name__ == '__main__':
    unittest.main()
