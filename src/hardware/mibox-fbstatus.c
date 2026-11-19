/* Live HDMI status screen for the slim image (follows plan A5's splash).
 *
 * After mibox-fbhandoff has verified fb0 (1280x1080, 32 bpp, R/G/B/A at bit
 * offsets 0/8/16/24, 5120-byte stride), this redraws once a second: a header
 * with the clock, status cards (network, SSH, uptime, memory, data) and a
 * tail of /dev/kmsg. It only reads system state; its only write is fb0.
 *
 *   mibox-fbstatus                  run on the box (custom root required)
 *   mibox-fbstatus --preview OUT.ppm [--kmsg FILE] [--run DIR] [--data PATH]
 *                  [--iface NAME] [--stretch]
 *                                   render one frame to a PPM on the host
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <net/if.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include "fbstatus-font.h"

#define W 1280
#define H 1080
#define STRIDE 5120

static uint32_t frame[W * H];
static uint32_t shown[W * H];
static volatile sig_atomic_t stop_requested;

/* fb0 bytes are R,G,B,A; on little-endian ARM that is r | g<<8 | b<<16 | a<<24. */
static uint32_t rgb(unsigned hex) {
    return (hex >> 16 & 255) | (hex >> 8 & 255) << 8 | (hex & 255) << 16 | 0xFF000000u;
}

enum {
    BG_TOP = 0x0A0F1E, BG_BOTTOM = 0x0F1629, HEADER = 0x0D1324, PANEL = 0x131A2C,
    BORDER = 0x232D47, TRACK = 0x232D47, TEXT = 0xD8E0EE, DIM = 0x7381A0, FAINT = 0x4A5675,
    CYAN = 0x4FD6C8, GREEN = 0x7BD88F, AMBER = 0xFFB454, RED = 0xFF6B6B, BLUE = 0x6CA8FF,
    VIOLET = 0xB48EFF, LOGTEXT = 0xB9C3D6,
};

static uint32_t mix(unsigned a, unsigned b, int t) {
    unsigned r = ((a >> 16 & 255) * (255 - t) + (b >> 16 & 255) * t) / 255;
    unsigned g = ((a >> 8 & 255) * (255 - t) + (b >> 8 & 255) * t) / 255;
    unsigned bl = ((a & 255) * (255 - t) + (b & 255) * t) / 255;
    return rgb(r << 16 | g << 8 | bl);
}

static void fill(int x, int y, int w, int h, uint32_t c) {
    for (int row = y < 0 ? 0 : y; row < y + h && row < H; row++)
        for (int col = x < 0 ? 0 : x; col < x + w && col < W; col++)
            frame[row * W + col] = c;
}

static void round_rect(int x, int y, int w, int h, int r, uint32_t c) {
    for (int row = 0; row < h; row++) {
        int dy = row < r ? r - row - 1 : row >= h - r ? row - (h - r) : -1;
        for (int col = 0; col < w; col++) {
            int dx = col < r ? r - col - 1 : col >= w - r ? col - (w - r) : -1;
            if (dx >= 0 && dy >= 0 && dx * dx + dy * dy >= r * r) continue;
            int px = x + col, py = y + row;
            if (px >= 0 && px < W && py >= 0 && py < H) frame[py * W + px] = c;
        }
    }
}

static void panel(int x, int y, int w, int h) {
    round_rect(x, y, w, h, 12, rgb(BORDER));
    round_rect(x + 1, y + 1, w - 2, h - 2, 11, rgb(PANEL));
}

static void dot(int cx, int cy, int r, uint32_t c) { round_rect(cx - r, cy - r, 2 * r, 2 * r, r, c); }

static int draw_text(const struct font *f, int x, int y, const char *s, unsigned color, int max_chars) {
    uint32_t c = rgb(color);
    for (int n = 0; *s && (max_chars < 0 || n < max_chars); s++, n++) {
        unsigned char ch = (unsigned char)*s;
        if (ch < 32 || ch > 126) ch = '?';
        const unsigned char *g = f->bits + (ch - 32) * f->h * f->stride;
        for (int row = 0; row < f->h; row++)
            for (int col = 0; col < f->w; col++)
                if (g[row * f->stride + col / 8] & (0x80 >> (col & 7))) {
                    int px = x + col, py = y + row;
                    if (px >= 0 && px < W && py >= 0 && py < H) frame[py * W + px] = c;
                }
        x += f->w;
    }
    return x;
}

static void bar(int x, int y, int w, int h, int percent, unsigned color) {
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    round_rect(x, y, w, h, h / 2, rgb(TRACK));
    int filled = w * percent / 100;
    if (filled >= h) round_rect(x, y, filled, h, h / 2, rgb(color));
}

/* ---- inputs ---------------------------------------------------------- */

static const char *run_dir = "/run";
static const char *data_path = "/mnt/mibox-data";
static const char *iface = "eth0";
static int preview;

static int read_text(const char *path, char *buffer, size_t size) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { buffer[0] = 0; return -1; }
    ssize_t n = read(fd, buffer, size - 1);
    close(fd);
    if (n < 0) { buffer[0] = 0; return -1; }
    buffer[n] = 0;
    while (n > 0 && (buffer[n - 1] == '\n' || buffer[n - 1] == ' ')) buffer[--n] = 0;
    return 0;
}

static int run_file(const char *name, char *buffer, size_t size) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", run_dir, name);
    return read_text(path, buffer, size);
}

static void human(unsigned long long bytes, char *out, size_t size) {
    if (bytes >= 1ULL << 30) snprintf(out, size, "%.1fG", bytes / (double)(1ULL << 30));
    else if (bytes >= 1ULL << 20) snprintf(out, size, "%lluM", bytes >> 20);
    else snprintf(out, size, "%lluK", bytes >> 10);
}

struct status {
    char ip[40], link[64], ssh[16], ssh_sub[40], uptime[48], load[64];
    unsigned ip_color, link_color, ssh_color;
    unsigned long long mem_total, mem_used, data_total, data_free;
    int data_mounted, synced;
    char host[65], kernel[65], machine[65];
};

static void gather_network(struct status *s) {
    struct ifreq req;
    memset(&req, 0, sizeof req);
    snprintf(req.ifr_name, sizeof req.ifr_name, "%s", iface);
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd >= 0 && ioctl(fd, SIOCGIFADDR, &req) == 0) {
        inet_ntop(AF_INET, &((struct sockaddr_in *)&req.ifr_addr)->sin_addr, s->ip, sizeof s->ip);
        s->ip_color = TEXT;
    } else {
        snprintf(s->ip, sizeof s->ip, "NO ADDRESS");
        s->ip_color = RED;
    }
    if (fd >= 0) close(fd);
    char path[256], carrier[16], speed[16], duplex[16];
    snprintf(path, sizeof path, "/sys/class/net/%s/carrier", iface);
    read_text(path, carrier, sizeof carrier);
    snprintf(path, sizeof path, "/sys/class/net/%s/speed", iface);
    read_text(path, speed, sizeof speed);
    snprintf(path, sizeof path, "/sys/class/net/%s/duplex", iface);
    read_text(path, duplex, sizeof duplex);
    if (strcmp(carrier, "1") == 0) {
        if (atoi(speed) > 0) snprintf(s->link, sizeof s->link, "%s up  %s Mb/s %s", iface, speed, duplex);
        else snprintf(s->link, sizeof s->link, "%s link up", iface);
        s->link_color = GREEN;
    } else {
        snprintf(s->link, sizeof s->link, "%s link down", iface);
        s->link_color = RED;
    }
}

static int count_processes(const char *name) {
    DIR *proc = opendir("/proc");
    if (!proc) return 0;
    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(proc))) {
        if (!isdigit((unsigned char)entry->d_name[0])) continue;
        char path[300], comm[32];
        snprintf(path, sizeof path, "/proc/%s/comm", entry->d_name);
        if (read_text(path, comm, sizeof comm) == 0 && strcmp(comm, name) == 0) count++;
    }
    closedir(proc);
    return count;
}

static void gather_ssh(struct status *s) {
    char scratch[64];
    int ready = run_file("mibox-alpine-ready", scratch, sizeof scratch) == 0;
    int stopping = run_file("mibox-alpine.stop", scratch, sizeof scratch) == 0;
    int procs = count_processes("dropbear");
    if (stopping) { snprintf(s->ssh, sizeof s->ssh, "STOPPED"); s->ssh_color = AMBER; }
    else if (ready && procs) { snprintf(s->ssh, sizeof s->ssh, "READY"); s->ssh_color = GREEN; }
    else if (ready) { snprintf(s->ssh, sizeof s->ssh, "RESTARTING"); s->ssh_color = AMBER; }
    else { snprintf(s->ssh, sizeof s->ssh, "WAITING"); s->ssh_color = AMBER; }
    int sessions = procs > 1 ? procs - 1 : 0;
    if (procs) snprintf(s->ssh_sub, sizeof s->ssh_sub, "%d session%s  :22", sessions, sessions == 1 ? "" : "s");
    else snprintf(s->ssh_sub, sizeof s->ssh_sub, "no dropbear");
}

static unsigned long long meminfo_kib(const char *text, const char *key) {
    const char *p = strstr(text, key);
    return p ? strtoull(p + strlen(key), NULL, 10) : 0;
}

static int is_mountpoint(const char *path) {
    FILE *f = fopen("/proc/self/mountinfo", "re");
    if (!f) return 0;
    char line[1024], mount[512];
    int found = 0;
    while (!found && fgets(line, sizeof line, f))
        if (sscanf(line, "%*s %*s %*s %*s %511s", mount) == 1 && strcmp(mount, path) == 0) found = 1;
    fclose(f);
    return found;
}

static void gather(struct status *s) {
    memset(s, 0, sizeof *s);
    struct utsname u;
    if (uname(&u) == 0) {
        snprintf(s->host, sizeof s->host, "%s", u.nodename);
        snprintf(s->kernel, sizeof s->kernel, "%s", u.release);
        snprintf(s->machine, sizeof s->machine, "%s", u.machine);
    }
    gather_network(s);
    gather_ssh(s);
    char text[2048];
    read_text("/proc/uptime", text, sizeof text);
    long up = atol(text);
    if (up >= 86400) snprintf(s->uptime, sizeof s->uptime, "%ldd %02ld:%02ld", up / 86400, up / 3600 % 24, up / 60 % 60);
    else snprintf(s->uptime, sizeof s->uptime, "%02ld:%02ld:%02ld", up / 3600, up / 60 % 60, up % 60);
    read_text("/proc/loadavg", text, sizeof text);
    double l1 = 0, l5 = 0, l15 = 0;
    sscanf(text, "%lf %lf %lf", &l1, &l5, &l15);
    snprintf(s->load, sizeof s->load, "load %.1f %.1f %.1f", l1, l5, l15);
    read_text("/proc/meminfo", text, sizeof text);
    unsigned long long total = meminfo_kib(text, "MemTotal:");
    unsigned long long avail = meminfo_kib(text, "MemAvailable:");
    if (!avail)  /* 3.10 predates MemAvailable */
        avail = meminfo_kib(text, "MemFree:") + meminfo_kib(text, "Buffers:") + meminfo_kib(text, "\nCached:");
    s->mem_total = total << 10;
    s->mem_used = (total > avail ? total - avail : 0) << 10;
    struct statvfs v;
    s->data_mounted = (preview || is_mountpoint(data_path)) && statvfs(data_path, &v) == 0;
    if (s->data_mounted) {
        s->data_total = (unsigned long long)v.f_blocks * v.f_frsize;
        s->data_free = (unsigned long long)v.f_bavail * v.f_frsize;
    }
    run_file("mibox-time-state", text, sizeof text);
    s->synced = strncmp(text, "SYNCED", 6) == 0;
}

/* ---- kernel log ------------------------------------------------------- */

#define LOG_CAPACITY 256
#define LOG_TEXT 240
struct log_line { double ts; int level; char text[LOG_TEXT]; };
static struct log_line logs[LOG_CAPACITY];
static unsigned log_count;

static void log_add(int level, double ts, const char *message, size_t length) {
    struct log_line *line = &logs[log_count++ % LOG_CAPACITY];
    line->ts = ts;
    line->level = level;
    size_t out = 0;
    for (size_t i = 0; i < length && out < LOG_TEXT - 1; i++) {
        unsigned ch = (unsigned char)message[i];
        /* kmsg escapes unprintable bytes as \xNN; decode, then drop controls. */
        if (ch == '\\' && i + 3 < length && message[i + 1] == 'x' &&
            isxdigit((unsigned char)message[i + 2]) && isxdigit((unsigned char)message[i + 3])) {
            char hex[3] = {message[i + 2], message[i + 3], 0};
            ch = (unsigned)strtoul(hex, NULL, 16);
            i += 3;
        }
        if (ch == '\t') ch = ' ';
        if (ch < 32 || ch > 126) continue;
        line->text[out++] = (char)ch;
    }
    while (out && line->text[out - 1] == ' ') out--;
    line->text[out] = 0;
}

/* /dev/kmsg record: "level,seq,usec,flags;message\n[ KEY=value\n...]" */
static void parse_record(const char *record) {
    unsigned long long usec = 0;
    unsigned prefix = 0;
    if (sscanf(record, "%u,%*u,%llu", &prefix, &usec) != 2) return;
    const char *message = strchr(record, ';');
    if (!message) return;
    message++;
    log_add(prefix & 7, usec / 1e6, message, strcspn(message, "\n"));
}

static void kmsg_drain(int fd) {
    char record[4096];
    for (;;) {
        ssize_t n = read(fd, record, sizeof record - 1);
        if (n < 0 && errno == EPIPE) continue;  /* overwritten records: skip ahead */
        if (n <= 0) return;
        record[n] = 0;
        parse_record(record);
    }
}

/* Preview input: kmsg records, or dmesg lines "[    6.848478@1] message". */
static void log_file(const char *path) {
    FILE *f = fopen(path, "re");
    if (!f) { perror(path); exit(1); }
    char line[1024];
    while (fgets(line, sizeof line, f)) {
        double ts = 0;
        int consumed = 0;
        if (isdigit((unsigned char)line[0]) && strchr(line, ';')) { parse_record(line); continue; }
        if (sscanf(line, " [ %lf%*[^]]] %n", &ts, &consumed) >= 1 && consumed)
            log_add(6, ts, line + consumed, strcspn(line + consumed, "\r\n"));
    }
    fclose(f);
}

static unsigned log_color(const struct log_line *line) {
    static const char *bad[] = {"FAIL", "ERROR", "rror", "INVALID", "UNAVAILABLE", "BELOW_FLOOR",
                                "panic", "Oops", "REFUS", NULL};
    for (int i = 0; bad[i]; i++) if (strstr(line->text, bad[i])) return RED;
    if (line->level <= 3) return RED;
    /* The 3.10 kernel logs most unlabelled printk at level 4, so level 4 is not a warning here. */
    if (strstr(line->text, "WARN") || strstr(line->text, "arning") || strstr(line->text, "deprecated")) return AMBER;
    if (strncmp(line->text, "mibox-", 6) == 0) {
        static const char *good[] = {"PASS", "READY", "SYNCED", "SHOWN", "MATCH", "RUNNING", "STARTING", NULL};
        for (int i = 0; good[i]; i++) if (strstr(line->text, good[i])) return GREEN;
        return CYAN;
    }
    return LOGTEXT;
}

/* ---- layout ----------------------------------------------------------- */

static void card(int x, int y, int w, int h, const char *label, unsigned accent, const char *value,
                 unsigned value_color, const char *sub, unsigned sub_color, int percent) {
    const struct font *big = &font_big, *small = &font_small;
    int inner = w - 32, max_big = inner / big->w, max_small = inner / small->w;
    panel(x, y, w, h);
    fill(x + 16, y + 1, w - 32, 3, rgb(accent));
    draw_text(small, x + 16, y + 16, label, DIM, max_small);
    draw_text(big, x + 16, y + 44, value, value_color, max_big);
    draw_text(small, x + 16, y + 86, sub, sub_color, max_small);
    if (percent >= 0) bar(x + 16, y + h - 26, inner, 10, percent, accent);
}

static void render(const struct status *s, unsigned tick) {
    const struct font *big = &font_big, *small = &font_small;
    for (int row = 0; row < H; row++) {
        uint32_t c = mix(BG_TOP, BG_BOTTOM, row * 255 / (H - 1));
        for (int col = 0; col < W; col++) frame[row * W + col] = c;
    }
    /* header */
    fill(0, 0, W, 78, rgb(HEADER));
    for (int col = 0; col < W; col++) {
        uint32_t c = mix(CYAN, VIOLET, col * 255 / (W - 1));
        for (int row = 78; row < 81; row++) frame[row * W + col] = c;
    }
    int x = draw_text(big, 28, 12, "MIBOX", CYAN, -1);
    draw_text(big, x + 12, 12, "custom os", TEXT, -1);
    char info[256];
    snprintf(info, sizeof info, "linux %s %s", s->kernel, s->machine);
    draw_text(small, 30, 50, info, DIM, 60);
    char clock[32], date[48];
    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    if (s->synced) {
        strftime(clock, sizeof clock, "%H:%M:%S", &local);
        strftime(date, sizeof date, "%Y-%m-%d %a", &local);
    } else {
        snprintf(clock, sizeof clock, "--:--:--");
        snprintf(date, sizeof date, "clock not synced");
    }
    draw_text(big, W - 28 - (int)strlen(clock) * big->w, 12, clock, s->synced ? TEXT : AMBER, -1);
    const char *ntp = s->synced ? "NTP" : "NTP pending";
    int right = W - 28 - (int)strlen(ntp) * small->w;
    draw_text(small, right, 50, ntp, s->synced ? GREEN : AMBER, -1);
    draw_text(small, right - 16 - (int)strlen(date) * small->w, 50, date, DIM, -1);

    /* status cards */
    const int top = 100, height = 150, margin = 28, gap = 14, first = 300;
    int each = (W - 2 * margin - first - 4 * gap) / 4;
    char value[48], sub[64], a[24], b[24];
    x = margin;
    card(x, top, first, height, "NETWORK", BLUE, s->ip, s->ip_color, s->link, s->link_color, -1);
    x += first + gap;
    card(x, top, each, height, "SSH", s->ssh_color, s->ssh, s->ssh_color, s->ssh_sub, DIM, -1);
    x += each + gap;
    card(x, top, each, height, "UPTIME", VIOLET, s->uptime, TEXT, s->load, DIM, -1);
    x += each + gap;
    int mem_percent = s->mem_total ? (int)(s->mem_used * 100 / s->mem_total) : 0;
    human(s->mem_used, a, sizeof a);
    human(s->mem_total, b, sizeof b);
    snprintf(value, sizeof value, "%s/%s", a, b);
    snprintf(sub, sizeof sub, "%d%% in use", mem_percent);
    unsigned mem_color = mem_percent >= 90 ? RED : mem_percent >= 75 ? AMBER : CYAN;
    card(x, top, each, height, "MEMORY", mem_color, value, TEXT, sub, DIM, mem_percent);
    x += each + gap;
    int last = W - margin - x;
    if (s->data_mounted) {
        human(s->data_free, a, sizeof a);
        human(s->data_total, b, sizeof b);
        snprintf(value, sizeof value, "%s free", a);
        snprintf(sub, sizeof sub, "of %s, min 256M", b);
        int used = s->data_total ? (int)((s->data_total - s->data_free) * 100 / s->data_total) : 0;
        unsigned color = s->data_free < 256ULL << 20 ? RED : s->data_free < 512ULL << 20 ? AMBER : GREEN;
        card(x, top, last, height, "DATA", color, value, TEXT, sub, DIM, used);
    } else {
        card(x, top, last, height, "DATA", AMBER, "NOT MOUNTED", AMBER, data_path, DIM, -1);
    }

    /* kernel log */
    const int log_top = 270, log_height = 760, line_height = 22, prefix = 9;
    panel(margin, log_top, W - 2 * margin, log_height);
    draw_text(small, margin + 20, log_top + 14, "KERNEL LOG", TEXT, -1);
    draw_text(small, margin + 20 + 11 * small->w, log_top + 14, "/dev/kmsg", FAINT, -1);
    int live_x = W - margin - 20 - 4 * small->w;
    draw_text(small, live_x, log_top + 14, "LIVE", GREEN, -1);
    dot(live_x - 14, log_top + 24, 5, rgb(tick & 1 ? GREEN : mix(GREEN, PANEL, 170)));
    fill(margin + 1, log_top + 46, W - 2 * margin - 2, 1, rgb(BORDER));
    int cols = (W - 2 * margin - 40) / small->w, text_cols = cols - prefix;
    int rows = (log_height - 60 - 8) / line_height;
    /* Walk back from the newest entry, wrapping long lines, then draw top-down. */
    struct { unsigned entry; int offset; } visible[64];
    int used = 0;
    unsigned available = log_count < LOG_CAPACITY ? log_count : LOG_CAPACITY;
    for (unsigned back = 0; back < available && used < rows; back++) {
        unsigned entry = (log_count - 1 - back) % LOG_CAPACITY;
        int length = (int)strlen(logs[entry].text);
        int pieces = length ? (length + text_cols - 1) / text_cols : 1;
        for (int piece = pieces - 1; piece >= 0 && used < rows; piece--) {
            visible[used].entry = entry;
            visible[used].offset = piece * text_cols;
            used++;
        }
    }
    int y = log_top + 60;
    for (int i = used - 1; i >= 0; i--, y += line_height) {
        const struct log_line *line = &logs[visible[i].entry];
        int lx = margin + 20;
        if (visible[i].offset == 0) {
            char stamp[24];
            snprintf(stamp, sizeof stamp, "%8.2f", line->ts);
            draw_text(small, lx, y, stamp, FAINT, prefix);
        }
        draw_text(small, lx + prefix * small->w, y, line->text + visible[i].offset, log_color(line), text_cols);
    }
    if (!used) draw_text(small, margin + 20, log_top + 60, "waiting for kernel messages", FAINT, -1);

    /* footer */
    snprintf(info, sizeof info, "ssh root@%s   |   usb adb 248243005297   |   serial ttyS0 115200 8n1", s->ip);
    draw_text(small, margin + 4, H - 38, info, FAINT, -1);
    draw_text(small, W - margin - 4 - 16 * small->w, H - 38, "refresh 1 second", FAINT, -1);
}

/* ---- outputs ---------------------------------------------------------- */

static int write_ppm(const char *path, int stretch) {
    FILE *f = fopen(path, "wbe");
    if (!f) { perror(path); return 1; }
    int width = stretch ? 1920 : W;
    fprintf(f, "P6\n%d %d\n255\n", width, H);
    for (int row = 0; row < H; row++)
        for (int col = 0; col < width; col++) {
            uint32_t p = frame[row * W + (stretch ? col * W / width : col)];
            unsigned char px[3] = {p & 255, p >> 8 & 255, p >> 16 & 255};
            fwrite(px, 1, 3, f);
        }
    return fclose(f) ? 1 : 0;
}

static void on_signal(int signal) { (void)signal; stop_requested = 1; }

static int run_device(void) {
    char buffer[1024];
    if (getuid() || geteuid() || read_text("/proc/1/root/etc/os-release", buffer, sizeof buffer) ||
        !strstr(buffer, "\nID=mibox-custom")) { fputs("custom root required\n", stderr); return 2; }
    int fd = open("/dev/fb0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("/dev/fb0"); return 1; }
    struct fb_var_screeninfo var;
    struct fb_fix_screeninfo fix;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &var) || ioctl(fd, FBIOGET_FSCREENINFO, &fix)) { perror("query"); return 1; }
    if (fix.type != FB_TYPE_PACKED_PIXELS || fix.visual != FB_VISUAL_TRUECOLOR || var.xres != W || var.yres != H ||
        var.bits_per_pixel != 32 || fix.line_length != STRIDE || var.xoffset ||
        var.yoffset + var.yres > var.yres_virtual || (unsigned long long)(var.yoffset + H) * STRIDE > fix.smem_len ||
        var.green.offset != 8 || var.transp.offset != 24 ||
        !((var.red.offset == 0 && var.blue.offset == 16) || (var.red.offset == 16 && var.blue.offset == 0))) {
        fputs("unexpected framebuffer layout\n", stderr);
        return 1;
    }
    /* Frames are drawn as RGBA (stock 3.10.33); the 3.10.99 BSP reports BGRA,
     * so red and blue are swapped while copying to fb0. */
    int bgra = var.red.offset == 16;
    static uint32_t row_out[W];
    unsigned char *map = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }
    uint32_t *screen = (uint32_t *)(map + (size_t)var.yoffset * STRIDE);
    int kmsg = open("/dev/kmsg", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, SIG_IGN);
    if (nice(10) == -1 && errno) perror("nice");
    memset(shown, 0, sizeof shown);  /* forces the first full copy */
    printf("MIBOX_FBSTATUS_RUNNING order=%s\n", bgra ? "bgra" : "rgba");
    fflush(stdout);
    for (unsigned tick = 0; !stop_requested; tick++) {
        if (kmsg >= 0) kmsg_drain(kmsg);
        struct status s;
        gather(&s);
        render(&s, tick);
        for (int row = 0; row < H; row++) {
            if (memcmp(frame + row * W, shown + row * W, W * 4) == 0) continue;
            if (bgra) {
                for (int col = 0; col < W; col++) {
                    uint32_t p = frame[row * W + col];
                    row_out[col] = (p & 0xFF00FF00u) | (p & 0xFFu) << 16 | (p >> 16 & 0xFFu);
                }
                memcpy(screen + row * W, row_out, W * 4);
            } else {
                memcpy(screen + row * W, frame + row * W, W * 4);
            }
            memcpy(shown + row * W, frame + row * W, W * 4);
        }
        struct timespec now, wait;
        clock_gettime(CLOCK_REALTIME, &now);  /* tick on the second so the clock is steady */
        wait.tv_sec = 0;
        wait.tv_nsec = 1000000000L - now.tv_nsec;
        nanosleep(&wait, NULL);
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *output = NULL, *kmsg_path = NULL;
    int stretch = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--preview") && i + 1 < argc) output = argv[++i];
        else if (!strcmp(argv[i], "--kmsg") && i + 1 < argc) kmsg_path = argv[++i];
        else if (!strcmp(argv[i], "--run") && i + 1 < argc) run_dir = argv[++i];
        else if (!strcmp(argv[i], "--data") && i + 1 < argc) data_path = argv[++i];
        else if (!strcmp(argv[i], "--iface") && i + 1 < argc) iface = argv[++i];
        else if (!strcmp(argv[i], "--stretch")) stretch = 1;
        else { fprintf(stderr, "unknown argument: %s\n", argv[i]); return 2; }
    }
    if (!output) {
        if (kmsg_path || stretch) { fputs("--kmsg/--stretch need --preview\n", stderr); return 2; }
        return run_device();
    }
    preview = 1;
    if (kmsg_path) log_file(kmsg_path);
    struct status s;
    gather(&s);
    render(&s, 1);
    return write_ppm(output, stretch);
}
