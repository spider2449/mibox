#ifndef MIBOX_FRAMEBUFFER_CAPTURE_H
#define MIBOX_FRAMEBUFFER_CAPTURE_H
#include <errno.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Accept only the bounded packed 32-bit layouts supported by this bring-up.
 * Use 64-bit arithmetic before adding any untrusted geometry fields. */
static int capture_layout(const struct fb_fix_screeninfo *f,
                          const struct fb_var_screeninfo *v) {
    uint64_t row_end=((uint64_t)v->xoffset+v->xres)*4;
    uint64_t last_row=(uint64_t)v->yoffset+v->yres;
    if(f->type!=FB_TYPE_PACKED_PIXELS || f->visual!=FB_VISUAL_TRUECOLOR ||
       v->bits_per_pixel!=32 || v->grayscale || v->nonstd || !v->xres || !v->yres ||
       v->xres>4096 || v->yres>2160 || row_end>f->line_length ||
       (uint64_t)v->xoffset+v->xres>v->xres_virtual || last_row>v->yres_virtual ||
       (uint64_t)v->yres*f->line_length>32u*1024*1024 ||
       (last_row-1)*f->line_length+row_end>f->smem_len) {errno=EINVAL;return -1;}
    struct fb_bitfield fields[4]={v->red,v->green,v->blue,v->transp};
    uint32_t used=0;
    for(unsigned i=0;i<4;i++) {
        struct fb_bitfield c=fields[i];
        if((i<3 && c.length!=8) || c.length>8 || c.offset>24 || c.msb_right) {errno=EINVAL;return -1;}
        uint32_t mask=((1u<<c.length)-1)<<c.offset;
        if(mask&used) {errno=EINVAL;return -1;} used|=mask;
    }
    return 0;
}

static int capture_write(int fd,const void *bytes,size_t count) {
    const uint8_t *p=bytes;
    while(count) {
        ssize_t n=write(fd,p,count);
        if(n<=0){if(!n)errno=EIO;return -1;}
        p+=n;count-=(size_t)n;
    }
    return 0;
}

/* One checked row at a time; alpha is ignored, and padding is never exported.
 * A live framebuffer can change while reading: this is not an atomic scanout. */
static int capture_ppm(int framebuffer,int output,const struct fb_fix_screeninfo *f,
                       const struct fb_var_screeninfo *v) {
    if(capture_layout(f,v))return -1;
    char header[64];int len=snprintf(header,sizeof header,"P6\n%u %u\n255\n",v->xres,v->yres);
    if(len<=0 || (size_t)len>=sizeof header || capture_write(output,header,(size_t)len))return -1;
    uint8_t *row=malloc((size_t)v->xres*4),*rgb=malloc((size_t)v->xres*3);
    if(!row || !rgb){free(row);free(rgb);errno=ENOMEM;return -1;}
    int result=-1;
    for(unsigned y=0;y<v->yres;y++) {
        uint64_t offset=((uint64_t)v->yoffset+y)*f->line_length+(uint64_t)v->xoffset*4;
        size_t count=(size_t)v->xres*4,read_count=0;
        while(read_count<count) {
            ssize_t n=pread(framebuffer,row+read_count,count-read_count,(off_t)(offset+read_count));
            if(n<=0){if(!n)errno=EIO;goto done;}read_count+=(size_t)n;
        }
        for(unsigned x=0;x<v->xres;x++) {
            /* MiBOX ARM uses little-endian pixels; decode explicitly for host tests. */
            const uint8_t *p=row+4*x;
            uint32_t pixel=(uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
            rgb[3*x]=(uint8_t)(pixel>>v->red.offset);
            rgb[3*x+1]=(uint8_t)(pixel>>v->green.offset);
            rgb[3*x+2]=(uint8_t)(pixel>>v->blue.offset);
        }
        if(capture_write(output,rgb,(size_t)v->xres*3))goto done;
    }
    result=0;
done:
    free(row);free(rgb);return result;
}
#endif
