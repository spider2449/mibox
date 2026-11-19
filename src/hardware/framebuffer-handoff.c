/* Reapply the exact queried fbdev geometry, pan and unblank; no raw MMIO. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/fb.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int text(const char *path, char *buffer, size_t size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buffer, size-1);
    close(fd);
    if (n < 0) return -1;
    buffer[n] = 0;
    return 0;
}

int main(void) {
    char buffer[1024];
    if (getuid() || geteuid() || text("/proc/1/root/etc/os-release", buffer, sizeof buffer) ||
        !strstr(buffer, "\nID=mibox-custom\n")) { fputs("custom root required\n", stderr); return 2; }
    /* Stock 3.10.33 or the pinned 3.10.99 container kernel (same Meson6 OSD
     * driver family); the layout checks below still gate every write. */
    if (text("/proc/sys/kernel/osrelease", buffer, sizeof buffer) ||
        (strcmp(buffer, "3.10.33\n") && strcmp(buffer, "3.10.99\n"))) return 2;
    if (text("/proc/device-tree/compatible", buffer, sizeof buffer)) return 2;
    { /* compatible may be NUL-separated; scan every entry. */
        ssize_t length = strnlen(buffer, sizeof buffer - 1) + 1;
        int board = 0;
        if (length < (ssize_t)sizeof buffer) {
            for (ssize_t offset = 0; offset < length; ) {
                size_t entry = strnlen(buffer + offset, sizeof buffer - 1 - offset);
                if (!entry) break;
                if (!strcmp(buffer + offset, "AMLOGIC,8726_MX")) board = 1;
                offset += entry + 1;
            }
        }
        if (!board) return 2;
    }
    int fd = open("/dev/fb0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open framebuffer"); return 1; }
    struct fb_var_screeninfo original, active, after;
    struct fb_fix_screeninfo fixed;
    int result = 1;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &original) || ioctl(fd, FBIOGET_FSCREENINFO, &fixed)) { perror("query"); goto done; }
    printf("before visible=%ux%u virtual=%ux%u offset=%u,%u bpp=%u stride=%u smem_len=%u\n",
           original.xres, original.yres, original.xres_virtual, original.yres_virtual,
           original.xoffset, original.yoffset, original.bits_per_pixel, fixed.line_length, fixed.smem_len);
    printf("format type=%u visual=%u r=%u/%u g=%u/%u b=%u/%u a=%u/%u nonstd=%u\n",
           fixed.type, fixed.visual, original.red.offset, original.red.length,
           original.green.offset, original.green.length, original.blue.offset, original.blue.length,
           original.transp.offset, original.transp.length, original.nonstd);
    /* Stock 3.10.33 reports RGBA (R at bit 0); the 3.10.99 BSP reports BGRA
     * (R at bit 16). Both are 8-bit channels with alpha at bit 24. */
    int rgba = original.red.offset == 0 && original.blue.offset == 16;
    int bgra = original.red.offset == 16 && original.blue.offset == 0;
    if (fixed.type != FB_TYPE_PACKED_PIXELS || fixed.visual != FB_VISUAL_TRUECOLOR ||
        original.xres != 1280 || original.yres != 1080 || original.xres_virtual != 1280 ||
        original.yres_virtual != 3240 || original.bits_per_pixel != 32 || fixed.line_length != 5120 ||
        original.xoffset || original.yoffset + original.yres > original.yres_virtual ||
        !(rgba || bgra) || original.red.length != 8 ||
        original.green.offset != 8 || original.green.length != 8 || original.blue.length != 8 ||
        original.transp.offset != 24 || original.transp.length != 8) {
        fputs("unexpected measured framebuffer layout\n", stderr); goto done;
    }
    active = original;
    active.activate = FB_ACTIVATE_NOW | FB_ACTIVATE_FORCE;
    if (ioctl(fd, FBIOPUT_VSCREENINFO, &active) || ioctl(fd, FBIOPAN_DISPLAY, &active) ||
        ioctl(fd, FBIOBLANK, FB_BLANK_UNBLANK) || ioctl(fd, FBIOGET_VSCREENINFO, &after)) {
        perror("same-geometry handoff"); goto done;
    }
    if (after.xres != original.xres || after.yres != original.yres ||
        after.xres_virtual != original.xres_virtual || after.yres_virtual != original.yres_virtual ||
        after.bits_per_pixel != original.bits_per_pixel || after.xoffset != original.xoffset || after.yoffset != original.yoffset) {
        fputs("geometry changed unexpectedly\n", stderr); goto done;
    }
    printf("FRAMEBUFFER_HANDOFF_PASS same_geometry=1 pan_current_offset=1 unblank=1 order=%s\n",
           rgba ? "rgba" : "bgra");
    result = 0;
done:
    close(fd);
    return result;
}
