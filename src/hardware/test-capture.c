#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
#include "framebuffer-capture.h"

static int temporary(void) {
    char path[]="/tmp/mibox-capture-test-XXXXXX";
    int fd=mkstemp(path);assert(fd>=0);assert(!unlink(path));return fd;
}
int main(void) {
    struct fb_fix_screeninfo f={.type=FB_TYPE_PACKED_PIXELS,.visual=FB_VISUAL_TRUECOLOR,.line_length=16,.smem_len=48};
    struct fb_var_screeninfo v={.xres=2,.yres=2,.xres_virtual=4,.yres_virtual=3,.xoffset=1,.yoffset=1,.bits_per_pixel=32,
        .red={0,8,0},.green={8,8,0},.blue={16,8,0},.transp={24,8,0}};
    int input=temporary(),output=temporary();
    uint8_t pixels[48];memset(pixels,0xad,sizeof pixels);
    const uint8_t a[]={255,0,0,17,0,255,0,99},b[]={0,0,255,3,12,34,56,0};
    memcpy(pixels+20,a,8);memcpy(pixels+36,b,8);
    assert(write(input,pixels,sizeof pixels)==sizeof pixels);
    assert(!capture_ppm(input,output,&f,&v));
    const uint8_t expected[]="P6\n2 2\n255\n\xff\0\0\0\xff\0\0\0\xff\x0c\x22\x38";
    uint8_t actual[128]={0};ssize_t n=pread(output,actual,sizeof actual,0);
    assert(n==(ssize_t)sizeof expected-1 && !memcmp(actual,expected,(size_t)n));
    puts("capture padded_rows_offsets_rgb_alpha_ignored=PASS");
    v.red.offset=16;v.blue.offset=0;
    assert(!ftruncate(output,0));assert(lseek(output,0,SEEK_SET)==0);
    assert(!capture_ppm(input,output,&f,&v));
    n=pread(output,actual,sizeof actual,0);
    assert(n==(ssize_t)sizeof expected-1 && actual[11]==0 && actual[13]==255 && actual[17]==255 && actual[19]==0);
    puts("capture bgr_channel_order=PASS");
    struct fb_var_screeninfo bad=v;
    bad.red.offset=bad.green.offset;assert(capture_layout(&f,&bad));
    bad=v;bad.bits_per_pixel=16;assert(capture_layout(&f,&bad));
    bad=v;bad.red.length=32;assert(capture_layout(&f,&bad));
    bad=v;bad.red.offset=32;assert(capture_layout(&f,&bad));
    bad=v;bad.transp.msb_right=1;assert(capture_layout(&f,&bad));
    bad=v;bad.xoffset=UINT32_MAX;assert(capture_layout(&f,&bad));
    bad=v;bad.yoffset=UINT32_MAX;assert(capture_layout(&f,&bad));
    bad=v;bad.xres=0;assert(capture_layout(&f,&bad));
    bad=v;bad.yres=2161;assert(capture_layout(&f,&bad));
    struct fb_fix_screeninfo small=f;small.smem_len=43;assert(capture_layout(&small,&v));
    small=f;small.line_length=8;assert(capture_layout(&small,&v));
    puts("capture invalid_layouts=PASS");
    assert(!ftruncate(input,40));assert(capture_ppm(input,output,&f,&v));
    assert(capture_ppm(-1,output,&f,&v));
    assert(capture_ppm(input,-1,&f,&v));
    puts("capture truncated_and_failed_io=PASS");
    close(input);close(output);
    /* Random geometry must be rejected or safe to allocate and address. */
    uint32_t seed=0x12345678;
    for(unsigned i=0;i<100000;i++) {
        seed=seed*1664525u+1013904223u;
        bad=v;bad.xoffset=seed;bad.yoffset=seed^0x87654321u;
        (void)capture_layout(&f,&bad);
    }
    puts("capture randomized_geometry_100000=PASS");return 0;
}
