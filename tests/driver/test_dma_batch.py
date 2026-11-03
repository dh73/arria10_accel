"""Run actual descriptor builder with independent mapped-segment fixtures."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = r'''
#ifndef MOCK_BATCH_H
#define MOCK_BATCH_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
typedef uint64_t u64;
typedef uint32_t u32;
typedef uint32_t __le32;
typedef uint64_t dma_addr_t;
struct device;
enum dma_data_direction { DMA_TO_DEVICE, DMA_FROM_DEVICE };
#define BUILD_BUG_ON(c) _Static_assert(!(c), "ABI")
#define check_add_overflow(a,b,p) __builtin_add_overflow(a,b,p)
#define min_t(t,a,b) ((t)(a)<(t)(b)?(t)(a):(t)(b))
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error Test fixture currently requires a little-endian host
#endif
#define cpu_to_le32(v) (v)
#endif
'''
TEST = r'''
#include "aclpci_dma_batch.c"
struct aclpci_user_dma { unsigned int count; u64 address[300]; size_t length[300]; };
bool aclpci_user_dma_matches_direction(const struct aclpci_user_dma *m, bool d) { (void)m; (void)d; return true; }
unsigned int aclpci_user_dma_segments(const struct aclpci_user_dma *m) { return m->count; }
int aclpci_user_dma_segment(const struct aclpci_user_dma *m, unsigned int i, dma_addr_t *a, size_t *n) {
    if(i>=m->count) return -EINVAL;
    *a=m->address[i]; *n=m->length[i]; return 0;
}
static u64 decode(const __le32 *p) {
    const unsigned char *b=(const unsigned char *)p; u64 v=0;
    for(int i=7;i>=0;--i) v=(v<<8)|b[i];
    return v;
}
int main(void) {
    struct aclpci_batch_descriptor table[128];
    struct aclpci_user_dma m;
    for(unsigned int offset=0;offset<4096;offset+=4) {
        m.count=257;
        for(unsigned int i=0;i<m.count;++i) {
            m.address[i]=0x100000000ULL+i*0x3000ULL;
            m.length[i]=4096;
        }
        m.address[0]+=offset; m.length[0]-=offset; m.length[256]=12;
        for(int dir=0;dir<2;++dir) {
            struct aclpci_batch_cursor cur={0,0,0x200000000ULL}, next;
            unsigned int first=127, seen=0, segment=0; size_t at=0;
            u64 device=cur.device_address;
            while(cur.segment<m.count) {
                unsigned int count=999; struct aclpci_batch_cursor saved=cur;
                assert(!aclpci_dma_build_batch(&m,&cur,first,dir,table,&count,&next));
                assert(!memcmp(&cur,&saved,sizeof(cur)));
                assert(count && count<=128-first);
                for(unsigned int i=0;i<count;++i) {
                    u64 src=decode(table[i].words), dst=decode(table[i].words+2);
                    u32 ctl=table[i].words[4]; size_t bytes=(ctl&0x3ffff)*4;
                    assert((ctl>>18)==first+i && bytes>=4 && bytes<=4096);
                    assert((bytes&(bytes-1))==0 && bytes<=m.length[segment]-at);
                    u64 host=m.address[segment]+at;
                    assert(src==(dir?device:host) && dst==(dir?host:device));
                    assert((host&4095)+bytes<=4096);
                    assert(!table[i].words[5] && !table[i].words[6] && !table[i].words[7]);
                    at+=bytes; device+=bytes; ++seen;
                    if(at==m.length[segment]) { ++segment; at=0; }
                }
                assert(next.segment==segment && next.offset==at && next.device_address==device);
                cur=next; first=(first+count)&127;
            }
            assert(segment==257 && seen>=257);
        }
    }
    struct aclpci_batch_cursor cur={0,0,4}, next;
    unsigned int count=9;
    m.count=1; m.address[0]=0; m.length[0]=4;
    assert(!aclpci_dma_build_batch(&m,&cur,0,false,table,&count,&next));
    assert(count==1 && decode(table[0].words)==0 && table[0].words[4]==1);
    m.address[0]=1; count=9;
    assert(aclpci_dma_build_batch(&m,&cur,0,false,table,&count,&next)==-EINVAL && !count);
    m.address[0]=0; cur.device_address=UINT64_MAX-3;
    assert(aclpci_dma_build_batch(&m,&cur,0,false,table,&count,&next)==-EOVERFLOW && !count);
    cur.device_address=4;
    assert(aclpci_dma_build_batch(&m,&cur,128,false,table,&count,&next)==-EINVAL && !count);
    return 0;
}
'''


class BatchTest(unittest.TestCase):
    def test_source_against_independent_descriptor_decoder(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work/'linux').mkdir()
            (work/'asm').mkdir()
            (work/'mock.h').write_text(HEADER)
            for name in ('kernel', 'overflow', 'string', 'types', 'dma-mapping'):
                (work/'linux'/f'{name}.h').write_text('#include "mock.h"\n')
            (work/'asm/byteorder.h').write_text('#include "mock.h"\n')
            (work/'test.c').write_text(TEST)
            binary = work/'test'
            subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                            '-I'+str(work), '-I'+str(ROOT/'drivers/aclpci'),
                            str(work/'test.c'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
