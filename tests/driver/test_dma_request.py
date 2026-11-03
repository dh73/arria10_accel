"""Actual request-owner and batch C code; mapped-device APIs are mocked."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_dma_batch import HEADER

ROOT = Path(__file__).resolve().parents[2]
TEST = r'''
#include "aclpci_dma_batch.c"
#include "aclpci_dma_request.c"
struct aclpci_user_dma { unsigned int count; bool released, dirty; };
bool aclpci_user_dma_matches_direction(const struct aclpci_user_dma *m, bool d) { (void)m; (void)d; return true; }
unsigned int aclpci_user_dma_segments(const struct aclpci_user_dma *m) { assert(!m->released); return m->count; }
int aclpci_user_dma_segment(const struct aclpci_user_dma *m, unsigned int i, dma_addr_t *a, size_t *n) {
    assert(!m->released); if(i>=m->count) return -EINVAL;
    *a=(u64)i*8192; *n=4096; return 0;
}
void aclpci_user_dma_release(struct aclpci_user_dma *m, bool dirty) {
    assert(!m->released); m->released=true; m->dirty=dirty;
}
int main(void) {
    struct aclpci_batch_descriptor table[128];
    /* Complete multi-table operation, both directions, no early release. */
    for(int direction=0; direction<2; ++direction) {
        struct aclpci_user_dma m={257,false,false};
        struct aclpci_dma_request r; u64 ticket=0; unsigned int batches=0;
        assert(!aclpci_dma_request_init(&r,&m,0,127,direction));
        while(r.phase!=ACLPCI_REQUEST_TERMINAL) {
            assert(aclpci_dma_request_release(&r)==-EBUSY && !m.released);
            assert(!aclpci_dma_request_build(&r,table));
            assert(aclpci_dma_request_retire(&r,ticket)==-ESTALE);
            assert(!aclpci_dma_request_submit(&r,&ticket));
            assert(ticket==++batches);
            assert(aclpci_dma_request_submit(&r,&ticket)==-EBUSY);
            assert(aclpci_dma_request_build(&r,table)==-EBUSY);
            assert(aclpci_dma_request_release(&r)==-EBUSY && !m.released);
            assert(aclpci_dma_request_retire(&r,ticket-1)==-ESTALE);
            assert(r.phase==ACLPCI_REQUEST_IN_FLIGHT);
            assert(!aclpci_dma_request_retire(&r,ticket));
            assert(aclpci_dma_request_retire(&r,ticket)==-ESTALE);
        }
        assert(batches==3 && r.cursor.segment==257 && r.result==0);
        assert(!aclpci_dma_request_release(&r) && m.released && m.dirty==(bool)direction);
        assert(aclpci_dma_request_release(&r)==-EINVAL);
    }
    /* Cancellation before build, after build, and during each batch. */
    for(int phase=0;phase<5;++phase) {
        struct aclpci_user_dma m={257,false,false};
        struct aclpci_dma_request r; u64 ticket=0;
        assert(!aclpci_dma_request_init(&r,&m,0,127,true));
        if(phase>=1) assert(!aclpci_dma_request_build(&r,table));
        if(phase>=2) {
            assert(!aclpci_dma_request_submit(&r,&ticket));
            for(int batch=2;batch<phase;++batch) {
                assert(!aclpci_dma_request_retire(&r,ticket));
                assert(!aclpci_dma_request_build(&r,table));
                assert(!aclpci_dma_request_submit(&r,&ticket));
            }
        }
        aclpci_dma_request_stop(&r);
        aclpci_dma_request_stop(&r);
        assert(aclpci_dma_request_build(&r,table)==-EBUSY);
        if(phase>=2) {
            assert(r.phase==ACLPCI_REQUEST_IN_FLIGHT);
            assert(aclpci_dma_request_release(&r)==-EBUSY && !m.released);
            assert(aclpci_dma_request_retire(&r,ticket+1)==-ESTALE);
            assert(!aclpci_dma_request_retire(&r,ticket));
        }
        assert(r.phase==ACLPCI_REQUEST_TERMINAL && r.result==-ECANCELED);
        assert(!aclpci_dma_request_release(&r) && m.dirty==(phase>=2));
    }
    struct aclpci_user_dma m={1,false,false};
    struct aclpci_dma_request r; u64 ticket;
    assert(!aclpci_dma_request_init(&r,&m,UINT64_MAX-3,0,false));
    assert(aclpci_dma_request_build(&r,table)==-EOVERFLOW);
    assert(!aclpci_dma_request_release(&r) && !m.dirty);
    m.released=false;
    assert(!aclpci_dma_request_init(&r,&m,0,0,false));
    assert(!aclpci_dma_request_build(&r,table)); r.sequence=UINT64_MAX;
    assert(aclpci_dma_request_submit(&r,&ticket)==-EOVERFLOW);
    assert(!aclpci_dma_request_release(&r) && !m.dirty);
    return 0;
}
'''


class RequestTest(unittest.TestCase):
    def test_request_retirement_and_stop(self):
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
