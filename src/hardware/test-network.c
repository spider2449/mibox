/* Linux network namespace fixture only; excluded from every device image. */
#define main hardware_main
#include "mibox-hardware.c"
#undef main
int main(void) {
    char current[128],initial[128];
    ssize_t a=readlink("/proc/self/ns/net",current,sizeof current-1),b=readlink("/proc/1/ns/net",initial,sizeof initial-1);
    if(getuid() || a<0 || b<0 || (a==b && !memcmp(current,initial,a)) || !getenv("MIBOX_ISOLATED_NET_FIXTURE"))return 2;
    struct sigaction action={0};action.sa_handler=stop;sigaction(SIGALRM,&action,NULL);alarm(40);
    return network(getenv("MIBOX_NETWORK_TEST_PROFILE")) ? 1 : 0;
}
