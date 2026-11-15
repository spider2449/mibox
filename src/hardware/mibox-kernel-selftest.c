#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/if_link.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/seccomp.h>
#include <linux/veth.h>
#include <net/if.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

/* Only launched by the experimental PID1. All mounts are in private RAM
 * namespaces; no device, persistent filesystem or network interface is used. */
static int failures;

static int text(const char *path, char *buffer, size_t size)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t count = read(fd, buffer, size - 1);
    close(fd);
    if (count < 0) return -1;
    buffer[count] = 0;
    return 0;
}

static int write_text(const char *path, const char *value)
{
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t size = strlen(value);
    ssize_t count = write(fd, value, size);
    close(fd);
    return count == (ssize_t)size ? 0 : -1;
}

static int wait_ok(pid_t pid)
{
    int status;
    return pid > 0 && waitpid(pid, &status, 0) == pid && WIFEXITED(status) && !WEXITSTATUS(status);
}

static void check(const char *name, int passed)
{
    printf("%s=%s\n", name, passed ? "PASS" : "FAIL");
    if (!passed) failures++;
}

struct link_request { struct nlmsghdr header; struct ifinfomsg info; char data[512]; };
static void attr(struct link_request *request, unsigned short type, const void *value, size_t size)
{
    size_t offset = NLMSG_ALIGN(request->header.nlmsg_len);
    if (offset + RTA_SPACE(size) > sizeof(*request)) _exit(90);
    struct rtattr *attribute = (void *)((char *)request + offset);
    attribute->rta_type = type;
    attribute->rta_len = RTA_LENGTH(size);
    if (size) memcpy(RTA_DATA(attribute), value, size);
    request->header.nlmsg_len = offset + RTA_SPACE(size);
}

static struct rtattr *nest(struct link_request *request, unsigned short type)
{
    size_t offset = NLMSG_ALIGN(request->header.nlmsg_len);
    attr(request, type, NULL, 0);
    return (void *)((char *)request + offset);
}

static void end_nest(struct link_request *request, struct rtattr *attribute)
{
    attribute->rta_len = (char *)request + request->header.nlmsg_len - (char *)attribute;
}

static int create_link(const char *name, const char *kind)
{
    struct link_request request = {0};
    request.header.nlmsg_len = NLMSG_LENGTH(sizeof(request.info));
    request.header.nlmsg_type = RTM_NEWLINK;
    request.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL;
    request.header.nlmsg_seq = 1;
    request.info.ifi_family = AF_UNSPEC;
    attr(&request, IFLA_IFNAME, name, strlen(name) + 1);
    struct rtattr *linkinfo = nest(&request, IFLA_LINKINFO);
    attr(&request, IFLA_INFO_KIND, kind, strlen(kind) + 1);
    if (!strcmp(kind, "veth")) {
        struct rtattr *data = nest(&request, IFLA_INFO_DATA);
        struct { struct ifinfomsg info; char attributes[32]; } peer = {0};
        struct rtattr *peer_name = (void *)peer.attributes;
        peer_name->rta_type = IFLA_IFNAME;
        peer_name->rta_len = RTA_LENGTH(sizeof("mibv1"));
        memcpy(RTA_DATA(peer_name), "mibv1", sizeof("mibv1"));
        attr(&request, VETH_INFO_PEER, &peer, sizeof(peer.info) + RTA_ALIGN(peer_name->rta_len));
        end_nest(&request, data);
    }
    end_nest(&request, linkinfo);
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (fd < 0) return 0;
    struct timeval timeout = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_nl address = {.nl_family = AF_NETLINK};
    char response[4096];
    int ok = sendto(fd, &request, request.header.nlmsg_len, 0,
                    (void *)&address, sizeof(address)) == (ssize_t)request.header.nlmsg_len;
    ssize_t size = ok ? recv(fd, response, sizeof(response), 0) : -1;
    close(fd);
    if (size < (ssize_t)NLMSG_LENGTH(sizeof(struct nlmsgerr))) return 0;
    struct nlmsghdr *header = (void *)response;
    struct nlmsgerr *error = NLMSG_DATA(header);
    return header->nlmsg_type == NLMSG_ERROR && !error->error && if_nametoindex(name);
}

static int namespace_test(void)
{
    if (unshare(CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWNET | CLONE_NEWPID)) return 1;
    if (mount(NULL, "/", NULL, MS_PRIVATE | MS_REC, NULL)) return 2;
    if (sethostname("mibox-container-test", strlen("mibox-container-test"))) return 3;
    if (!create_link("mibv0", "veth") || !if_nametoindex("mibv1")) return 4;
    if (!create_link("mibbr0", "bridge")) return 5;
    if (mkdir("/tmp/mibox-ns", 0700) || mount("tmpfs", "/tmp/mibox-ns", "tmpfs", MS_NOSUID | MS_NODEV, "size=64k")) return 6;
    pid_t child = fork();
    if (!child) _exit(getpid() == 1 ? 0 : 7);
    return wait_ok(child) ? 0 : 8;
}

static int seccomp_test(void)
{
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_getppid, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
    };
    struct sock_fprog program = {.len = sizeof(instructions) / sizeof(instructions[0]), .filter = instructions};
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program)) return 1;
    errno = 0;
    return syscall(SYS_getppid) == -1 && errno == EPERM ? 0 : 2;
}

static int cgroup_test(const char *controller, const char *file, const char *value)
{
    char mountpoint[128], group[160], setting[240], actual[128];
    snprintf(mountpoint, sizeof(mountpoint), "/tmp/mibox-cgroup-%s", controller);
    snprintf(group, sizeof(group), "%s/probe", mountpoint);
    snprintf(setting, sizeof(setting), "%s/%s", group, file);
    if (mkdir(mountpoint, 0700) || mount("cgroup", mountpoint, "cgroup", MS_NOSUID | MS_NODEV | MS_NOEXEC, controller)) return 0;
    if (mkdir(group, 0700) || write_text(setting, value) || text(setting, actual, sizeof(actual))) return 0;
    int ok = strtoll(actual, NULL, 10) == strtoll(value, NULL, 10);
    if (rmdir(group) || umount(mountpoint)) return 0;
    return ok;
}

int main(void)
{
    char marker[256], compatible[256], hostname[256], after[256];
    struct utsname system;
    setvbuf(stdout, NULL, _IONBF, 0);
    if (geteuid() || getppid() != 1 || uname(&system) ||
        strcmp(system.release, "3.10.99") ||
        text("/etc/mibox-kernel-development", marker, sizeof(marker)) ||
        strcmp(marker, "MIBOX_KERNEL_DEV_V1 8b1bb2b31a8e94b773a4b8ab907a0473a0951192 3.10.99-mibox-container-dev+\n") ||
        text("/proc/device-tree/compatible", compatible, sizeof(compatible)) ||
        strcmp(compatible, "AMLOGIC,8726_MX")) {
        puts("MIBOX_KERNEL_SELFTEST_GUARD_REFUSED");
        return 2;
    }
    alarm(30);
    puts("MIBOX_KERNEL_SELFTEST_V1");
    printf("kernel=%s\n", system.release);
    if (unshare(CLONE_NEWNS) || mount(NULL, "/", NULL, MS_PRIVATE | MS_REC, NULL)) return 3;
    if (gethostname(hostname, sizeof(hostname))) return 4;
    pid_t child = fork();
    if (!child) _exit(namespace_test());
    check("namespace_pid1_veth_bridge_tmpfs", wait_ok(child));
    check("parent_uts_and_net_unchanged", !gethostname(after, sizeof(after)) && !strcmp(hostname, after) && !if_nametoindex("mibv0"));
    child = fork();
    if (!child) _exit(unshare(CLONE_NEWUSER) ? 1 : 0);
    check("user_namespace", wait_ok(child));
    child = fork();
    if (!child) _exit(seccomp_test());
    check("seccomp_filter_enforcement", wait_ok(child));
    check("memory_cgroup_limit_readback", cgroup_test("memory", "memory.limit_in_bytes", "16777216"));
    check("cpu_cgroup_quota_readback", cgroup_test("cpu", "cpu.cfs_quota_us", "50000"));
    printf("MIBOX_KERNEL_SELFTEST_%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
