/* Fixed single-variable boot environment update; no arbitrary flash command. */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include "rescue-env-payload.h"

#define REGION 32768
#define TOTAL 4194304
#define NODE "/proc/1/root/tmp/mibox-env-window-device"

#ifndef RESCUE_ENV_FIXTURE
static int text_is(const char *path, const char *expected) {
    char buf[128]; FILE *f=fopen(path,"r");
    if(!f) return 0;
    size_t n=fread(buf,1,sizeof(buf)-1,f); fclose(f); buf[n]=0;
    buf[strcspn(buf,"\r\n")]=0;
    return !strcmp(buf,expected);
}
#endif

static int transfer(int fd, void *buf, size_t count, off_t offset, int writing) {
    size_t done=0;
    while(done<count) {
        size_t length=count-done;
#ifdef RESCUE_ENV_FIXTURE
        if(writing && getenv("MIBOX_ENV_TEST_INTERRUPT")) {
            if(done>=512) {errno=EINTR; return -1;}
            length=512;
        }
#endif
        ssize_t n=writing ? pwrite(fd,(char*)buf+done,length,offset+done)
                          : pread(fd,(char*)buf+done,length,offset+done);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) {if(!n)errno=EIO; return -1;}
        done+=(size_t)n;
    }
    return 0;
}

static int check_or_write(int fd, int mode) {
    unsigned char *data=malloc(TOTAL);
    if(!data) return 1;
    int result=1;
    if(transfer(fd,data,TOTAL,0,0)) {perror("read full environment"); goto out;}
    /* Validate the ENTIRE region, including untouched tail, before any write. */
    if(mode==3) {
        if(memcmp(data+REGION,original_env+REGION,TOTAL-REGION)) goto out;
        for(size_t i=0;i<REGION;i++) if(data[i]!=original_env[i] && data[i]!=window_env[i]) {
            fputs("not a recognized interrupted update; no write\n",stderr); goto out;
        }
    } else if(mode==2) {
        if(memcmp(data,window_env,REGION) || memcmp(data+REGION,original_env+REGION,TOTAL-REGION)) {
            fputs("installed environment mismatch; no write\n",stderr); goto out;
        }
    } else if(memcmp(data,original_env,TOTAL)) {
        fputs("original environment mismatch; no write\n",stderr); goto out;
    }
    if(!mode) {puts("MIBOX_ENV_CHECK_OK original_exact=1 bytes=4194304"); result=0; goto out;}
    const unsigned char *next=mode>=2 ? original_env : window_env;
    fputs("MIBOX_ENV_WRITE_STARTED region=0:32768\n",stderr); fflush(stderr);
    if(transfer(fd,(void*)next,REGION,0,1) || fsync(fd)) {
        perror("environment write/fsync: target may be partial; keep RAM session alive"); goto out;
    }
#ifndef RESCUE_ENV_FIXTURE
    if(ioctl(fd,BLKFLSBUF)) {perror("environment cache flush: write not verified"); goto out;}
#else
    if(getenv("MIBOX_ENV_TEST_CORRUPT")) {
        unsigned char bad=next[0]^1;
        if(pwrite(fd,&bad,1,0)!=1 || fsync(fd)) goto out;
    }
#endif
    if(transfer(fd,data,TOTAL,0,0) || memcmp(data,next,REGION) ||
       memcmp(data+REGION,original_env+REGION,TOTAL-REGION)) {
        fputs("environment full readback mismatch; keep RAM session alive\n",stderr); goto out;
    }
    puts(mode>=2 ? "MIBOX_ENV_REMOVED full_readback_match=1" : "MIBOX_ENV_INSTALLED full_readback_match=1");
    result=0;
out:
    free(data); return result;
}

int main(int argc,char **argv) {
    int mode;
    if(argc<2) return 2;
    if(!strcmp(argv[1],"--check")) mode=0;
    else if(!strcmp(argv[1],"--install")) mode=1;
    else if(!strcmp(argv[1],"--remove")) mode=2;
    else if(!strcmp(argv[1],"--recover-original")) mode=3;
    else return 2;
    int fd=-1,result=1; struct stat info;
#ifdef RESCUE_ENV_FIXTURE
    if(argc!=3) return 2;
    fd=open(argv[2],(mode?O_RDWR:O_RDONLY)|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0 || fstat(fd,&info) || !S_ISREG(info.st_mode) || info.st_size!=TOTAL) goto cleanup;
#else
    if(argc!=2 || getuid()!=0) return 2;
    FILE *os=fopen("/proc/1/root/etc/os-release","r"); char osline[256]; int custom=0;
    if(!os) return 2;
    while(fgets(osline,sizeof(osline),os)) {
        osline[strcspn(osline,"\r\n")]=0;
        if(!strcmp(osline,"ID=mibox-custom"))custom=1;
    }
    fclose(os);
    if(!custom || !text_is("/proc/sys/kernel/osrelease","3.10.33")) return 2;
    if(!text_is("/sys/class/block/env/dev","179:3") ||
       !text_is("/sys/class/block/env/size","8192") ||
       !text_is("/sys/class/block/env/ro","0")) return 2;
    struct statfs ram;
    if(statfs("/proc/1/root/tmp",&ram) || (unsigned long)ram.f_type!=0x858458f6UL) return 2;
    FILE *mounts=fopen("/proc/self/mountinfo","r"); char line[4096];
    if(!mounts) return 2;
    while(fgets(line,sizeof(line),mounts)) {
        unsigned a,b;
        if(sscanf(line,"%*u %*u %u:%u",&a,&b)==2 && a==179 && b==3) {fclose(mounts);return 2;}
    }
    fclose(mounts);
    if(mknod(NODE,S_IFBLK|0600,makedev(179,3))) {perror("exclusive env node");return 2;}
    fd=open(NODE,(mode?O_RDWR|O_SYNC:O_RDONLY)|O_NOFOLLOW|O_CLOEXEC);
    uint64_t size=0;
    if(fd<0 || fstat(fd,&info) || !S_ISBLK(info.st_mode) ||
       major(info.st_rdev)!=179 || minor(info.st_rdev)!=3 ||
       ioctl(fd,BLKGETSIZE64,&size) || size!=TOTAL) goto cleanup;
#endif
    result=check_or_write(fd,mode);
cleanup:
    if(fd>=0) close(fd);
#ifndef RESCUE_ENV_FIXTURE
    unlink(NODE);
#endif
    return result;
}
