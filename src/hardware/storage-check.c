/* Bounded filesystem test; paths are exclusive children of an existing directory. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <unistd.h>

static int error(const char *what) { perror(what); return 1; }
static unsigned char pattern(size_t offset, unsigned round) {
    uint32_t v = (uint32_t)offset ^ ((uint32_t)round * 0x9e3779b9U);
    v ^= v >> 16; v *= 0x7feb352dU; v ^= v >> 15;
    return (unsigned char)v;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: storage-check NEW-EXCLUSIVE-DIRECTORY\n"); return 2; }
    /* Caller must verify mount identity. This helper independently limits usage. */
    const size_t sizes[] = {4096, 1048576, 16777216};
    struct statfs space;
    char *parent = strdup(argv[1]);
    if (!parent) return error("strdup");
    char *slash = strrchr(parent, '/');
    if (!slash || slash == parent || !slash[1]) { free(parent); return 2; }
    *slash = 0;
    int pfd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    free(parent);
    if (pfd < 0) return error("parent open");
    if (fstatfs(pfd, &space)) { close(pfd); return error("statfs"); }
    uint64_t available = (uint64_t)space.f_bavail * space.f_bsize;
    if (space.f_type != 0xef53 || available < 256ULL*1048576 + sizes[2] || sizes[2] > available/10) {
        fprintf(stderr, "requires ext filesystem, 256 MiB reserve and <=10%% free usage\n");
        close(pfd); return 2;
    }
    if (mkdir(argv[1], 0700)) { close(pfd); return error("exclusive mkdir"); }
    int dir = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (dir < 0) { close(pfd); return error("directory open"); }
    int result = 1, fd = -1;
    unsigned char buffer[8192];
    if (fsync(pfd)) { error("parent fsync"); goto cleanup; }
    for (unsigned round = 0; round < 10; round++) {
        for (size_t test = 0; test < sizeof sizes / sizeof sizes[0]; test++) {
            size_t size = sizes[test];
            fd = openat(dir, "writing", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (fd < 0) { error("create"); goto cleanup; }
            for (size_t offset = 0; offset < size;) {
                /* Non-power-of-two requests exercise tail and partial-buffer handling. */
                size_t count = size - offset;
                if (count > 4093) count = 4093;
                for (size_t i = 0; i < count; i++) buffer[i] = pattern(offset+i, round);
                size_t done = 0;
                while (done < count) {
                    ssize_t n = write(fd, buffer+done, count-done);
                    if (n < 0 && errno == EINTR) continue;
                    if (n <= 0) { error("write"); goto cleanup; }
                    done += (size_t)n;
                }
                offset += count;
            }
            if (fsync(fd)) { error("file fsync"); goto cleanup; }
            if (close(fd)) { fd = -1; error("file close"); goto cleanup; }
            fd = -1;
            if (renameat(dir, "writing", dir, "reading") || fsync(dir)) { error("rename/directory fsync"); goto cleanup; }
            fd = openat(dir, "reading", O_RDONLY | O_NOFOLLOW);
            if (fd < 0) { error("reopen"); goto cleanup; }
            size_t offset = 0;
            for (;;) {
                ssize_t n = read(fd, buffer, sizeof buffer);
                if (n < 0 && errno == EINTR) continue;
                if (n < 0) { error("read"); goto cleanup; }
                if (!n) break;
                if ((size_t)n > size-offset) { fprintf(stderr, "oversized file\n"); goto cleanup; }
                for (ssize_t i = 0; i < n; i++) if (buffer[i] != pattern(offset+(size_t)i, round)) {
                    fprintf(stderr, "mismatch round=%u offset=%zu\n", round, offset+(size_t)i); goto cleanup;
                }
                offset += (size_t)n;
            }
            if (close(fd)) { fd = -1; error("read close"); goto cleanup; }
            fd = -1;
            if (offset != size) { fprintf(stderr, "truncated read\n"); goto cleanup; }
            if (unlinkat(dir, "reading", 0) || fsync(dir)) { error("unlink/directory fsync"); goto cleanup; }
            printf("PASS round=%u bytes=%zu file_fsync=1 directory_fsync=1 reopened_compare=1\n", round, size);
            fflush(stdout);
        }
    }
    result = 0;
cleanup:
    if (fd >= 0) close(fd);
    /* Only fixed child names in this invocation's newly created directory. */
    if (unlinkat(dir, "writing", 0) && errno != ENOENT) result = 1;
    if (unlinkat(dir, "reading", 0) && errno != ENOENT) result = 1;
    if (fsync(dir)) result = 1;
    if (close(dir)) result = 1;
    if (rmdir(argv[1])) { error("directory cleanup"); result = 1; }
    if (fsync(pfd)) result = 1;
    close(pfd);
    if (!result) puts("STORAGE_SHORT_PASS cleanup=1 cache_excluded=0 reboot_tested=0 forced_short_write_tested=0 interruption_tested=0");
    return result;
}
