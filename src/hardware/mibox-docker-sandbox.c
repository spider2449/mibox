#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Fixed RAM-only entry. The parent retains the namespace leader's outer PID,
 * so the deadline kills that leader and therefore every descendant, even when
 * a shell or daemon has ignored TERM. No host process-group kill is used. */
int main(int argc, char **argv)
{
    struct utsname version;
    struct stat st;
    char compatible[128] = {0};
    if (argc != 1) {
        fprintf(stderr, "inspect-only: fixed RAM Docker sandbox; no arguments accepted\n");
        return 2;
    }
    (void)argv;
    int fd = open("/proc/device-tree/compatible", O_RDONLY | O_CLOEXEC);
    ssize_t count = fd >= 0 ? read(fd, compatible, sizeof(compatible) - 1) : -1;
    if (fd >= 0) close(fd);
    const char *board = "AMLOGIC,8726_MX";
#ifdef MIBOX_DOCKER_QEMU_TEST
    board = "linux,dummy-virt";
#endif
#ifdef MIBOX_DOCKER_QEMU_LEGACY_TEST
    board = "arm,vexpress";
#endif
    if (getuid() || geteuid() || uname(&version) ||
#if defined(MIBOX_DOCKER_QEMU_LEGACY_TEST)
        strncmp(version.release, "3.10.", 5) ||
#elif !defined(MIBOX_DOCKER_QEMU_TEST)
        strcmp(version.release, "3.10.99") ||
#else
        strncmp(version.release, "6.1.", 4) ||
#endif
        count < 0 || !memmem(compatible, (size_t)count, board, strlen(board))) {
        fprintf(stderr, "sandbox hardware/release/credential guard rejected\n");
        return 2;
    }
    fd = open("/run/mibox-docker-stage/root", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 || fstat(fd, &st) || st.st_uid || (st.st_mode & 0777) != 0700) {
        fprintf(stderr, "sandbox RAM root guard rejected\n");
        return 2;
    }
    if (unshare(CLONE_NEWNS | CLONE_NEWNET | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWPID) ||
        mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL)) {
        perror("sandbox unshare/private");
        return 1;
    }
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 1; }
    if (!child) {
        close(fd);
        if (mount("tmpfs", "/run/mibox-docker-stage/root", "tmpfs", MS_NOSUID | MS_NODEV,
                  "mode=700,size=384m")) { perror("sandbox tmpfs"); _exit(1); }
        pid_t extractor = fork();
        if (extractor < 0) { perror("extract fork"); _exit(1); }
        if (!extractor) {
            execl("/bin/busybox", "busybox", "tar", "-xzf",
                  "/run/mibox-docker-stage/payload.tar.gz", "-C",
                  "/run/mibox-docker-stage/root", (char *)NULL);
            perror("extract exec"); _exit(1);
        }
        int extracted;
        while (waitpid(extractor, &extracted, 0) < 0) {
            if (errno != EINTR) { perror("extract wait"); _exit(1); }
        }
        if (!WIFEXITED(extracted) || WEXITSTATUS(extracted)) _exit(1);
        fd = open("/run/mibox-docker-stage/root", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) { perror("open mounted root"); _exit(1); }
        /* initramfs rootfs cannot be pivot_root'ed. Move our independent tmpfs
         * onto the namespace root and change this PID1's root with it. Unlike
         * BusyBox switch_root, never unlink the shared original rootfs. */
        if (fchdir(fd) || mount(".", "/", NULL, MS_MOVE, NULL) || chroot(".") || chdir("/")) {
            perror("sandbox move root"); _exit(1);
        }
        close(fd);
        execl("/bin/sh", "sh", "/sbin/mibox-docker-experiment", (char *)NULL);
        perror("sandbox exec");
        _exit(1);
    }
    close(fd);
    struct timespec start, now, delay = {0, 100000000};
    if (clock_gettime(CLOCK_MONOTONIC, &start)) { kill(child, SIGKILL); return 1; }
    int status;
    for (;;) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) break;
        if (result < 0 && errno != EINTR) { perror("waitpid"); kill(child, SIGKILL); return 1; }
        if (clock_gettime(CLOCK_MONOTONIC, &now) || now.tv_sec - start.tv_sec >= 240) {
            kill(child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            fprintf(stderr, "sandbox deadline: namespace leader killed\n");
            return 124;
        }
        nanosleep(&delay, NULL);
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
