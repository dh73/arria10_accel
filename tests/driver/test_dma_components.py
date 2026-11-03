"""All three actual C components together; only kernel services are mocked."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_user_dma import MOCK

ROOT = Path(__file__).resolve().parents[2]
EXTRA = r'''
typedef uint64_t u64;
typedef uint32_t u32;
typedef uint32_t __le32;
#define BUILD_BUG_ON(c) _Static_assert(!(c), "ABI")
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error This fixture requires a little-endian host
#endif
#define cpu_to_le32(v) (v)
'''
TEST = r'''
#include "aclpci_user_dma.c"
#include "aclpci_dma_batch.c"
#include "aclpci_dma_request.c"
int main(void) {
    struct device dev={0};
    struct aclpci_batch_descriptor table[128];
    for(int dir=DMA_TO_DEVICE;dir<=DMA_FROM_DEVICE;++dir) {
        for(int cancel=0;cancel<2;++cancel) {
            struct aclpci_user_dma *m=NULL;
            struct aclpci_dma_request r;
            struct aclpci_batch_cursor cursor={0,0,0}, next;
            unsigned int count=999;
            bool reading=dir==DMA_FROM_DEVICE;
            u64 ticket=0;
            pin_result=INT_MAX; max_map=4096; task.mm=&user_mm;
            alloc_call=0; map_call=0;
            assert(!aclpci_user_dma_prepare(&dev,0x10000,12288,dir,&m));
            assert(pins==3 && maps==3 && user_mm.charged==3 && user_mm.refs==1);
            assert(aclpci_dma_request_init(&r,m,0,127,!reading)==-EINVAL);
            assert(aclpci_dma_build_batch(m,&cursor,0,!reading,table,&count,&next)==-EINVAL);
            assert(count==0 && pins==3 && maps==3); /* ownership not consumed */
            assert(!aclpci_dma_request_init(&r,m,0,127,reading));
            assert(!aclpci_dma_request_build(&r,table) && r.count==1);
            assert(!aclpci_dma_request_submit(&r,&ticket));
            task.mm=NULL; /* process has exited; deferred path uses retained mm */
            if(cancel) aclpci_dma_request_stop(&r);
            assert(aclpci_dma_request_release(&r)==-EBUSY);
            assert(pins==3 && maps==3 && user_mm.charged==3 && user_mm.refs==1);
            assert(!aclpci_dma_request_retire(&r,ticket));
            if(!cancel) {
                assert(r.phase==ACLPCI_REQUEST_READY && r.cursor.segment==1);
                assert(pins==3 && maps==3); /* retain even the first retired page */
                assert(!aclpci_dma_request_build(&r,table) && r.count==2);
                assert(!aclpci_dma_request_submit(&r,&ticket));
                assert(aclpci_dma_request_retire(&r,ticket-1)==-ESTALE);
                assert(aclpci_dma_request_release(&r)==-EBUSY);
                assert(!aclpci_dma_request_retire(&r,ticket));
            }
            assert(r.phase==ACLPCI_REQUEST_TERMINAL);
            assert(r.result==(cancel?-ECANCELED:0));
            assert(!aclpci_dma_request_release(&r));
            assert(!pins && !maps && !user_mm.charged && !user_mm.refs && !dev.refs && !live_alloc);
            assert(dirty==reading);
        }
    }
    return 0;
}
'''


class ComponentsTest(unittest.TestCase):
    def test_real_components_and_direction_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work/'linux/sched').mkdir(parents=True)
            (work/'asm').mkdir()
            (work/'mock.h').write_text(MOCK.replace('#endif\n', EXTRA+'\n#endif\n'))
            for name in ('device','err','limits','mm','overflow','sched','slab',
                         'vmalloc','dma-mapping','sched/mm','kernel','types','string'):
                (work/'linux'/f'{name}.h').write_text('#include "mock.h"\n')
            (work/'asm/byteorder.h').write_text('#include "mock.h"\n')
            (work/'test.c').write_text(TEST)
            binary = work/'test'
            subprocess.run(['cc','-std=gnu11','-Wall','-Wextra','-Werror',
                            '-I'+str(work),'-I'+str(ROOT/'drivers/aclpci'),
                            str(work/'test.c'),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)


if __name__ == '__main__':
    unittest.main()
