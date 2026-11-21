"""Host fault injection for the actual vendor ring allocator, not a device test."""
import argparse
from pathlib import Path
import subprocess
import tempfile

STUBS = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define printk printf
#define GFP_KERNEL 1
#define GFP_ATOMIC 2
#define GFP_DMA 4
#define RX_RING_SIZE 8
#define TX_RING_SIZE 8
#define PKT_BUF_SZ 1536
#define IS_CACHE_ALIGNED(p) 1
typedef uintptr_t dma_addr_t;
struct _rx_desc { unsigned long value; };
struct _tx_desc { unsigned long value; };
struct am_net_private {
    unsigned rx_buf_sz;
    struct _rx_desc *rx_ring, *rx_ring_dma;
    struct _tx_desc *tx_ring, *tx_ring_dma;
};
struct net_device { unsigned mtu; int dev; struct am_net_private priv; };
#define netdev_priv(dev) (&(dev)->priv)
static int calls, fail_at, live, initialized;
static void *kmalloc(size_t size, unsigned flags)
{
    assert((flags & GFP_ATOMIC) && !(flags & GFP_KERNEL));
    if (++calls == fail_at) return NULL;
    void *p = calloc(1, size);
    assert(p);
    live++;
    return p;
}
static void kfree(void *p) { assert(p); live--; free(p); }
static uintptr_t virt_to_phys(void *p) { assert(p); return (uintptr_t)p; }
static void *dma_alloc_coherent(int *dev, size_t size, dma_addr_t *addr, unsigned flags)
{
    void *p = kmalloc(size, flags);
    if (p) *addr = (uintptr_t)p;
    return p;
}
static void dma_free_coherent(int *dev, size_t size, void *p, dma_addr_t addr)
{
    assert(addr == (uintptr_t)p);
    kfree(p);
}
static int init_rxtx_rings(struct net_device *dev)
{
    assert(dev->priv.rx_ring && dev->priv.tx_ring);
    initialized++;
    return 0;
}
'''

MAIN = r'''
int main(void)
{
    for (int failure = 1; failure <= 3; failure++) {
        struct net_device dev = { .mtu = 1500 };
        calls = live = initialized = 0;
        fail_at = failure;
        int result = alloc_ringdesc(&dev);
        if (failure <= 2) {
            assert(result == -ENOMEM);
            assert(!live && !initialized);
            assert(!dev.priv.rx_ring && !dev.priv.tx_ring);
        } else {
            assert(!result && live == 2 && initialized == 1);
            kfree(dev.priv.rx_ring);
            kfree(dev.priv.tx_ring);
            assert(!live);
        }
    }
    puts("PASS: RX failure, TX failure cleanup, successful initialization");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    text = (args.source / 'drivers/amlogic/ethernet/am_net8218.c').read_text()
    start = text.index('static int alloc_ringdesc(')
    end = text.index('\n/* --------------------------------------------------------------------------*/', start)
    allocator = text[start:end]
    with tempfile.TemporaryDirectory(prefix='mibox-ringalloc-') as directory:
        source = Path(directory) / 'test.c'
        binary = Path(directory) / 'test'
        source.write_text(STUBS + allocator + MAIN)
        for coherent in (False, True):
            command = ['cc', '-std=gnu99', '-fsanitize=address,undefined',
                       '-g', '-o', str(binary), str(source)]
            if coherent:
                command.append('-DUSE_COHERENT_MEMORY')
            subprocess.run(command, check=True)
            print(f'coherent={coherent}', flush=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
