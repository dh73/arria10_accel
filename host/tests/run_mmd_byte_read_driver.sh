#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$1
mkdir -p "$out/linux/sched" "$out/asm"
for h in device err limits mm overflow sched slab vmalloc dma-mapping errno kernel string types workqueue mutex spinlock atomic completion wait kref; do
 printf '#include "aclpci_dma_test_kernel.h"\n' > "$out/linux/$h.h"
done
printf '#include "aclpci_dma_test_kernel.h"\n' > "$out/linux/sched/mm.h"
printf '#include "aclpci_dma_test_kernel.h"\n' > "$out/asm/byteorder.h"
cc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g -I "$root/drivers/aclpci/tests" -I "$out" -DACLPCI_DMA_TEST -DACLPCI_FILEIO_TEST -c "$root/drivers/aclpci/tests/dma_receipt_client_fixture.c" -o "$out/fixture.o"
c++ -std=c++17 -Wall -Wextra -Wpedantic -Werror -I "$root/host/include" -I "$root/host/mmd" -I "$root/third_party/fpga-runtime-for-opencl/include" -I "$root/drivers/aclpci" "$root/host/src/aclpci_dma_receipt.cpp" "$root/host/src/aclpci_dma_client.cpp" "$root/host/tests/mmd_byte_read_driver_test.cpp" "$out/fixture.o" -o "$out/test"
"$out/test"
