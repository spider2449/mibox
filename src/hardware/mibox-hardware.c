/* Explicit, bounded tests for the custom RAM system. No shell or block I/O. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <net/route.h>
#include <poll.h>
#include <signal.h>
#include <sound/asound.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
#include "framebuffer-capture.h"

static volatile sig_atomic_t interrupted;
static void stop(int sig) { (void)sig; interrupted = 1; }
static int fail(const char *s) { fprintf(stderr, "FAIL %s: %s\n", s, strerror(errno)); return -1; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int readtext(const char *p, char *b, size_t n) {
    int fd = open(p, O_RDONLY | O_CLOEXEC); if (fd < 0) return -1;
    ssize_t r = read(fd, b, n-1); close(fd); if (r < 0) return -1; b[r] = 0; return 0;
}
static int guard(void) {
    char b[8192]={0};
    if (getuid() || geteuid() || getppid() != 1) { errno = EPERM; return fail("root child of PID1 required"); }
    if (readtext("/etc/os-release", b, sizeof b)) return fail("custom marker read");
    int marker=0;char *state=NULL;
    for(char *line=strtok_r(b,"\r\n",&state);line;line=strtok_r(NULL,"\r\n",&state))if(!strcmp(line,"ID=mibox-custom"))marker=1;
    if(!marker) {errno=EPERM;return fail("custom marker");}
    if (readtext("/proc/sys/kernel/osrelease", b, sizeof b) || strcmp(b, "3.10.33\n")) { errno = EPERM; return fail("stock kernel guard"); }
    int fd = open("/proc/device-tree/compatible", O_RDONLY); if (fd < 0) return fail("DT compatible");
    ssize_t n = read(fd, b, sizeof b - 1); close(fd); int board = 0;
    if (n > 0) { b[n] = 0; for (ssize_t i=0; i<n;) { size_t k = strnlen(b+i, n-i); if (!strcmp(b+i, "AMLOGIC,8726_MX")) board=1; i += k+1; } }
    if (!board) { errno = EPERM; return fail("board guard"); }
    FILE *f = fopen("/proc/mounts", "r"); if (!f) return fail("mounts");
    char source[256], path[256], type[64], rest[1024]; int ram = 0, valid = 1;
    while (fscanf(f, "%255s %255s %63s", source, path, type) == 3) {
        if (!fgets(rest, sizeof rest, f)) { valid=0; break; }
        int memory = !strcmp(type,"rootfs") || !strcmp(type,"ramfs") || !strcmp(type,"tmpfs");
        if (!strcmp(path,"/")) ram=memory;
        if (!memory && strcmp(type,"proc") && strcmp(type,"sysfs") && strcmp(type,"devtmpfs") && strcmp(type,"devpts") && strcmp(type,"functionfs")) valid=0;
    }
    fclose(f); if (!ram || !valid) { errno=EPERM; return fail("RAM-only mounts"); }
    return 0;
}
static void addr(struct sockaddr *s, uint32_t ip) {
    struct sockaddr_in *a=(void *)s; memset(a,0,sizeof *a); a->sin_family=AF_INET; a->sin_addr.s_addr=ip;
}
static int setip(int fd, unsigned long cmd, uint32_t ip) {
    struct ifreq r={0}; strcpy(r.ifr_name,"eth0"); addr(&r.ifr_addr,ip); return ioctl(fd,cmd,&r);
}
static uint16_t sum16(const void *p, size_t n) {
    const uint8_t *b=p; uint32_t s=0; for (;n>1;n-=2,b+=2) s+=((uint32_t)b[0]<<8)|b[1];
    if(n) s+=(uint32_t)b[0]<<8; while(s>>16) s=(s&65535)+(s>>16); return htons((uint16_t)~s);
}
static void put16(uint8_t *p,uint16_t n) { n=htons(n); memcpy(p,&n,2); }
static uint16_t get16(const uint8_t *p) { uint16_t n; memcpy(&n,p,2); return ntohs(n); }
struct lease { uint32_t ip, mask, router, server, seconds; uint8_t kind; };
/* Validate BOOTP identity and strict single-instance DHCP options. */
static int parse(const uint8_t *p,size_t n,uint32_t xid,const uint8_t mac[6],struct lease *l) {
    if(n<240 || p[0]!=2 || p[1]!=1 || p[2]!=6 || memcmp(p+4,&xid,4) || memcmp(p+28,mac,6) || memcmp(p+236,"\x63\x82\x53\x63",4)) return -1;
    memset(l,0,sizeof *l); memcpy(&l->ip,p+16,4); uint8_t seen[256]={0}; int end=0;
    for(size_t i=240;i<n;) {
        unsigned tag=p[i++]; if(tag==255) {end=1;break;} if(!tag) continue;
        if(i>=n) return -1; size_t len=p[i++]; if(i+len>n || seen[tag]++) return -1;
        switch(tag) {
        case 53: if(len!=1) return -1; l->kind=p[i]; break;
        case 1: if(len!=4) return -1; memcpy(&l->mask,p+i,4); break;
        case 3: if(!len || len%4) return -1; memcpy(&l->router,p+i,4); break;
        case 54: if(len!=4) return -1; memcpy(&l->server,p+i,4); break;
        case 51: if(len!=4) return -1; memcpy(&l->seconds,p+i,4); l->seconds=ntohl(l->seconds); break;
        case 52: return -1; /* Option overload is unsupported, never guessed. */
        }
        i+=len;
    }
    return end && l->kind ? 0 : -1;
}
static int senddhcp(int fd,int index,const uint8_t mac[6],uint32_t xid,int kind,const struct lease *l) {
    uint8_t b[600]={0}; uint8_t *p=b+28;
    p[0]=1;p[1]=1;p[2]=6;memcpy(p+4,&xid,4);p[10]=128;memcpy(p+28,mac,6);memcpy(p+236,"\x63\x82\x53\x63",4);
    size_t k=240;p[k++]=53;p[k++]=1;p[k++]=(uint8_t)kind;
    p[k++]=61;p[k++]=7;p[k++]=1;memcpy(p+k,mac,6);k+=6;
    if(kind==3) {p[k++]=50;p[k++]=4;memcpy(p+k,&l->ip,4);k+=4;p[k++]=54;p[k++]=4;memcpy(p+k,&l->server,4);k+=4;}
    p[k++]=57;p[k++]=2;put16(p+k,576);k+=2;
    p[k++]=55;p[k++]=4;p[k++]=1;p[k++]=3;p[k++]=51;p[k++]=54;p[k++]=255;
    if(k<300) k=300;
    b[0]=0x45;put16(b+2,(uint16_t)(k+28));b[8]=64;b[9]=17;memset(b+16,255,4);uint16_t check=sum16(b,20);memcpy(b+10,&check,2);
    put16(b+20,68);put16(b+22,67);put16(b+24,(uint16_t)(k+8));
    uint8_t pseudo[612]={0};memset(pseudo+4,255,4);pseudo[9]=17;put16(pseudo+10,(uint16_t)(k+8));memcpy(pseudo+12,b+20,k+8);
    check=sum16(pseudo,k+20);if(!check)check=0xffff;memcpy(b+26,&check,2);
    struct sockaddr_ll to={0};to.sll_family=AF_PACKET;to.sll_protocol=htons(0x0800);to.sll_ifindex=index;to.sll_halen=6;memset(to.sll_addr,255,6);
    return sendto(fd,b,k+28,0,(void *)&to,sizeof to)==(ssize_t)(k+28) ? 0 : -1;
}
static int receivedhcp(int fd,uint32_t xid,const uint8_t mac[6],int kind,struct lease *out) {
    double deadline=now()+4;unsigned frames=0,ipv4=0,udp=0,dhcp=0,logged=0;
    while(!interrupted && now()<deadline) {
        struct pollfd p={fd,POLLIN,0}; if(poll(&p,1,100)<=0) continue;
        uint8_t frame[2048];ssize_t frame_size=recv(fd,frame,sizeof frame,0);if(frame_size<14)continue;frames++;
        size_t ethernet=14;uint16_t protocol=get16(frame+12);
        for(int tag=0;tag<2 && (protocol==0x8100 || protocol==0x88a8);tag++) {if((size_t)frame_size<ethernet+4)break;protocol=get16(frame+ethernet+2);ethernet+=4;}
        if(protocol!=0x0800 || (size_t)frame_size<ethernet+28)continue;
        uint8_t *b=frame+ethernet;ssize_t n=frame_size-(ssize_t)ethernet;if(b[0]>>4!=4)continue;ipv4++;
        size_t h=(b[0]&15)*4, total=get16(b+2);
        if(h<20 || total>(size_t)n || total<h+8 || b[9]!=17 || (get16(b+6)&0x3fff)) continue;udp++;
        if(get16(b+h)!=67 || get16(b+h+2)!=68) continue;
        dhcp++;
        if(logged++<3) {printf("dhcp_rx frame_bytes=%zd ip_total=%zu ip_checksum=%04x udp_length=%u xid=",frame_size,total,ntohs(sum16(b,h)),get16(b+h+4));
            size_t available=total-h-8;uint8_t *bootp=b+h+8;for(size_t j=4;j<8 && j<available;j++)printf("%02x",bootp[j]);
            printf(" options=");for(size_t j=236;j<available && j<380;j++)printf("%02x",bootp[j]);puts("");}
        if(sum16(b,h)!=0)continue;
        size_t u=get16(b+h+4); if(u<8 || h+u>total) continue;
        if(get16(b+h+6)) {uint8_t pseudo[2060]={0};memcpy(pseudo,b+12,8);pseudo[9]=17;put16(pseudo+10,(uint16_t)u);memcpy(pseudo+12,b+h,u);if(sum16(pseudo,u+12))continue;}
        struct lease l; if(!parse(b+h+8,u-8,xid,mac,&l)) {
            if(l.kind==6) {errno=ECONNREFUSED;return -1;}
            if(l.kind==kind) {*out=l;return 0;}
        }
    }
    printf("dhcp_wait kind=%d frames=%u ipv4=%u udp=%u server_replies=%u\n",kind,frames,ipv4,udp,dhcp);
    errno=ETIMEDOUT;return -1;
}
static int conflict(int index,const uint8_t mac[6],uint32_t ip) {
    int fd=socket(AF_PACKET,SOCK_DGRAM|SOCK_CLOEXEC,htons(0x0806));if(fd<0)return -1;
    struct sockaddr_ll to={0};to.sll_family=AF_PACKET;to.sll_protocol=htons(0x0806);to.sll_ifindex=index;to.sll_halen=6;memset(to.sll_addr,255,6);
    if(bind(fd,(void *)&to,sizeof to)) {close(fd);return -1;}
    uint8_t a[28]={0};put16(a,1);put16(a+2,0x0800);a[4]=6;a[5]=4;put16(a+6,1);memcpy(a+8,mac,6);memcpy(a+24,&ip,4);
    for(int i=0;i<3 && !interrupted;i++) {
        if(sendto(fd,a,sizeof a,0,(void *)&to,sizeof to)!=sizeof a) {close(fd);return -1;}
        double end=now()+1;
        while(!interrupted && now()<end) {
            struct pollfd p={fd,POLLIN,0};if(poll(&p,1,100)<=0)continue;
            uint8_t b[256];ssize_t n=recv(fd,b,sizeof b,0);
            if(n>=28 && get16(b)==1 && get16(b+2)==0x0800 && b[4]==6 && b[5]==4 && memcmp(b+8,mac,6) &&
               (!memcmp(b+14,&ip,4) || (get16(b+6)==1 && !memcmp(b+24,&ip,4)))) {close(fd);errno=EADDRINUSE;return -1;}
        }
    }
    close(fd);return interrupted ? -1 : 0;
}
static int ping_gateway(uint32_t gateway) {
    int fd=socket(AF_INET,SOCK_RAW|SOCK_CLOEXEC,IPPROTO_ICMP);if(fd<0)return fail("ICMP socket");
    if(setsockopt(fd,SOL_SOCKET,SO_BINDTODEVICE,"eth0",5)) {close(fd);return fail("ICMP bind eth0");}
    struct sockaddr_in to={.sin_family=AF_INET,.sin_addr={gateway}};int count=0;
    uint8_t request[32]={8,0};uint16_t id=htons((uint16_t)getpid());memcpy(request+4,&id,2);
    for(int seq=1;seq<=3 && !interrupted;seq++) {
        put16(request+6,(uint16_t)seq);memset(request+2,0,2);uint16_t c=sum16(request,sizeof request);memcpy(request+2,&c,2);
        if(sendto(fd,request,sizeof request,0,(void *)&to,sizeof to)!=sizeof request)break;
        double end=now()+2;
        while(!interrupted && now()<end) {
            struct pollfd p={fd,POLLIN,0};if(poll(&p,1,100)<=0)continue;
            uint8_t b[2048];ssize_t n=recv(fd,b,sizeof b,0);if(n<20)continue;size_t h=(b[0]&15)*4;
            if(h<20 || n!=(ssize_t)(h+sizeof request) || memcmp(b+12,&gateway,4) || b[h]!=0 || b[h+1]!=0 || memcmp(b+h+4,request+4,sizeof request-4) || sum16(b+h,n-h)) continue;
            count++;break;
        }
    }
    close(fd);printf("gateway_echo_replies=%d/3\n",count);return count==3 ? 0 : -1;
}
static int static_profile(const char *path,struct lease *lease) {
    if(!path)return 0;
    int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0)return errno==ENOENT ? 0 : -1;
    struct stat st;char content[128]={0};
    if(fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid || st.st_gid || (st.st_mode&0022)) {close(fd);errno=EPERM;return -1;}
    ssize_t n=read(fd,content,sizeof content-1);close(fd);
    if(n<1 || n==(ssize_t)sizeof content-1 || memchr(content,0,n)) {errno=EINVAL;return -1;}
    char address[16],mask[16],gateway[16],extra;
    if(sscanf(content,"MIBOX_STATIC_IPV4_V1 %15s %15s %15s %c",address,mask,gateway,&extra)!=3 ||
       inet_pton(AF_INET,address,&lease->ip)!=1 || inet_pton(AF_INET,mask,&lease->mask)!=1 || inet_pton(AF_INET,gateway,&lease->router)!=1) {errno=EINVAL;return -1;}
    return 1;
}
static int network(const char *profile) {
    int fd=socket(AF_INET,SOCK_DGRAM|SOCK_CLOEXEC,0), packet=-1, capture=-1, result=-1, changed=0, route_added=0;
    struct ifreq r={0};strcpy(r.ifr_name,"eth0");struct rtentry route={0};uint32_t old_ip=0,old_mask=0;
    if(fd<0)return fail("network socket");
    if(ioctl(fd,SIOCGIFFLAGS,&r))goto done;short flags=r.ifr_flags;
    if(flags&IFF_UP) {errno=EBUSY;fail("eth0 must initially be down");goto done;}
    if(!ioctl(fd,SIOCGIFADDR,&r))old_ip=((struct sockaddr_in *)&r.ifr_addr)->sin_addr.s_addr;
    else if(errno!=EADDRNOTAVAIL)goto done;
    if(old_ip) {errno=EBUSY;fail("existing IPv4 address");goto done;}
    if(!ioctl(fd,SIOCGIFNETMASK,&r))old_mask=((struct sockaddr_in *)&r.ifr_netmask)->sin_addr.s_addr;
    struct lease offer={0},ack={0};int fixed=static_profile(profile,&ack);
    if(fixed<0) {fail("static IPv4 profile");goto done;}
    if(ioctl(fd,SIOCGIFHWADDR,&r))goto done;uint8_t mac[6];memcpy(mac,r.ifr_hwaddr.sa_data,6);
    unsigned index=if_nametoindex("eth0");if(!index)goto done;
    r.ifr_flags=flags|IFF_UP;if(ioctl(fd,SIOCSIFFLAGS,&r))goto done;changed=1;
    char carrier[32];int link=0;for(int i=0;i<40 && !interrupted;i++) {if(!readtext("/sys/class/net/eth0/carrier",carrier,sizeof carrier) && carrier[0]=='1'){link=1;break;}usleep(100000);}
    if(!link) {errno=ENOLINK;fail("Ethernet carrier");goto cleanup;}
    if(!fixed) {
    packet=socket(AF_PACKET,SOCK_DGRAM|SOCK_CLOEXEC,htons(0x0800));if(packet<0)goto cleanup;
    struct sockaddr_ll bindto={0};bindto.sll_family=AF_PACKET;bindto.sll_protocol=htons(0x0800);bindto.sll_ifindex=(int)index;
    if(bind(packet,(void *)&bindto,sizeof bindto))goto cleanup;
    capture=socket(AF_PACKET,SOCK_RAW|SOCK_CLOEXEC,htons(0x0003));if(capture<0)goto cleanup;
    bindto.sll_protocol=htons(0x0003);if(bind(capture,(void *)&bindto,sizeof bindto))goto cleanup;
    uint32_t xid;int random=open("/dev/urandom",O_RDONLY);if(random<0)goto cleanup;ssize_t got=read(random,&xid,4);close(random);if(got!=4)goto cleanup;
    int offered=0;
    for(int i=0;i<3 && !interrupted;i++) {if(senddhcp(packet,index,mac,xid,1,NULL))goto cleanup;if(!receivedhcp(capture,xid,mac,2,&offer)){offered=1;break;}}
    if(!offered || !offer.ip || !offer.server) {fail("DHCP offer");goto cleanup;}
    if(senddhcp(packet,index,mac,xid,3,&offer) || receivedhcp(capture,xid,mac,5,&ack)) {fail("DHCP ACK");goto cleanup;}
    }
    uint32_t mask=ntohl(ack.mask), ip=ntohl(ack.ip), gw=ntohl(ack.router);
    if((!fixed && (ack.server!=offer.server || ack.ip!=offer.ip || ack.seconds<60)) || !mask || ((~mask+1)&~mask) ||
       !ip || ip>=0xe0000000 || !gw || (ip&mask)!=(gw&mask) || !(ip&~mask) || (ip&~mask)==~mask || ip==gw) {errno=EINVAL;fail(fixed ? "static IPv4 contract" : "DHCP lease contract");goto cleanup;}
    if(conflict(index,mac,ack.ip)) {fail("IPv4 conflict probe");goto cleanup;}
    if(setip(fd,SIOCSIFADDR,ack.ip) || setip(fd,SIOCSIFNETMASK,ack.mask)) {fail("IPv4 configuration");goto cleanup;}
    addr(&route.rt_dst,0);addr(&route.rt_genmask,0);addr(&route.rt_gateway,ack.router);route.rt_flags=RTF_UP|RTF_GATEWAY;route.rt_dev="eth0";
    if(ioctl(fd,SIOCADDRT,&route)) {fail("default route");goto cleanup;}route_added=1;
    char a[INET_ADDRSTRLEN],b[INET_ADDRSTRLEN],c[INET_ADDRSTRLEN];
    inet_ntop(AF_INET,&ack.ip,a,sizeof a);inet_ntop(AF_INET,&ack.mask,b,sizeof b);inet_ntop(AF_INET,&ack.router,c,sizeof c);
    if(fixed)printf("static_address=%s netmask=%s gateway=%s source=rootfs_profile\n",a,b,c);
    else printf("dhcp_address=%s netmask=%s gateway=%s lease_seconds=%u\n",a,b,c,ack.seconds);
    fflush(stdout);
    result=ping_gateway(ack.router);
cleanup:
    if(packet>=0)close(packet);
    if(capture>=0)close(capture);
    if(route_added && ioctl(fd,SIOCDELRT,&route)) {fail("remove test route");result=-1;}
    if(changed) {
        if(setip(fd,SIOCSIFADDR,old_ip)) {fail("restore address");result=-1;}
        /* A down, unaddressed interface has no configured netmask to restore. */
        if(old_ip && setip(fd,SIOCSIFNETMASK,old_mask))result=-1;
        memset(&r,0,sizeof r);strcpy(r.ifr_name,"eth0");r.ifr_flags=flags;
        if(ioctl(fd,SIOCSIFFLAGS,&r)) {fail("restore flags");result=-1;}
        printf("network_cleanup=%s\n",result==0 ? "ok" : "attempted; inspect state");
    }
done:
    close(fd);if(result)fail("network test");else puts("MIBOX_ETHERNET_TEST_OK");return result;
}

static uint32_t channel(unsigned n,struct fb_bitfield c) {
    if(!c.length)return 0;return (uint32_t)(((uint64_t)n*((1u<<c.length)-1)/255)<<c.offset);
}
static int capture(void);
static int display(void) {
    int fd=open("/dev/graphics/fb0",O_RDWR|O_CLOEXEC);if(fd<0)fd=open("/dev/fb0",O_RDWR|O_CLOEXEC);
    if(fd<0)return fail("framebuffer open");struct fb_fix_screeninfo f;struct fb_var_screeninfo v;int result=-1;
    if(ioctl(fd,FBIOGET_FSCREENINFO,&f) || ioctl(fd,FBIOGET_VSCREENINFO,&v))goto done;
    printf("fb_id=%.16s visible=%ux%u virtual=%ux%u offset=%u,%u bpp=%u stride=%u smem_len=%u\n",f.id,v.xres,v.yres,v.xres_virtual,v.yres_virtual,v.xoffset,v.yoffset,v.bits_per_pixel,f.line_length,f.smem_len);
    printf("rgba=%u:%u,%u:%u,%u:%u,%u:%u\n",v.red.offset,v.red.length,v.green.offset,v.green.length,v.blue.offset,v.blue.length,v.transp.offset,v.transp.length);
    uint64_t start=(uint64_t)v.yoffset*f.line_length, size=(uint64_t)v.yres*f.line_length;
    if(f.type!=FB_TYPE_PACKED_PIXELS || f.visual!=FB_VISUAL_TRUECOLOR || v.bits_per_pixel!=32 || v.grayscale || v.nonstd || !v.xres || !v.yres ||
       v.xres>4096 || v.yres>2160 || (uint64_t)v.xoffset+v.xres>v.xres_virtual || (uint64_t)v.yoffset+v.yres>v.yres_virtual ||
       ((uint64_t)v.xoffset+v.xres)*4>f.line_length || size>32*1024*1024 || start+size>f.smem_len ||
       v.red.length!=8 || v.green.length!=8 || v.blue.length!=8 || v.transp.length>8 ||
       v.red.offset>24 || v.green.offset>24 || v.blue.offset>24 || v.transp.offset>24 ||
       v.red.msb_right || v.green.msb_right || v.blue.msb_right || v.transp.msb_right) {errno=EINVAL;fail("unsupported framebuffer layout");goto done;}
    uint32_t masks[4]={channel(255,v.red),channel(255,v.green),channel(255,v.blue),channel(255,v.transp)};
    for(int i=0;i<4;i++)for(int j=i+1;j<4;j++)if(masks[i]&masks[j]) {errno=EINVAL;fail("overlapping channels");goto done;}
    uint8_t *saved=malloc(size),*pattern=malloc(size);if(!saved || !pattern){free(saved);free(pattern);goto done;}
    if(pread(fd,saved,size,start)!=(ssize_t)size){fail("save framebuffer");free(saved);free(pattern);goto done;}
    memcpy(pattern,saved,size);
    const unsigned colors[8][3]={{255,255,255},{255,255,0},{0,255,255},{0,255,0},{255,0,255},{255,0,0},{0,0,255},{0,0,0}};
    for(unsigned y=0;y<v.yres;y++)for(unsigned x=0;x<v.xres;x++) {
        unsigned bar=(uint64_t)x*8/v.xres;uint32_t pixel=channel(colors[bar][0],v.red)|channel(colors[bar][1],v.green)|channel(colors[bar][2],v.blue)|channel(255,v.transp);
        memcpy(pattern+(uint64_t)y*f.line_length+(v.xoffset+x)*4,&pixel,4);
    }
    if(pwrite(fd,pattern,size,start)==(ssize_t)size) {
        /* The bootloader logo can remain scanned out from a different buffer.
         * Reapply the exact queried geometry, pan to its current offset and
         * unblank through fbdev; never write a guessed physical address. */
        struct fb_var_screeninfo activate=v;activate.activate=FB_ACTIVATE_NOW|FB_ACTIVATE_FORCE;
        if(ioctl(fd,FBIOPUT_VSCREENINFO,&activate) || ioctl(fd,FBIOPAN_DISPLAY,&activate) || ioctl(fd,FBIOBLANK,FB_BLANK_UNBLANK))fail("framebuffer handoff");
        else {puts("framebuffer_handoff=same_geometry,pan,unblank");puts("MIBOX_HDMI_PATTERN_ACTIVE duration_seconds=15 bars=white,yellow,cyan,green,magenta,red,blue,black");fflush(stdout);result=capture();double end=now()+15;while(!interrupted && now()<end)usleep(100000);}
    }
    else fail("write test pattern");
    if(pwrite(fd,saved,size,start)!=(ssize_t)size) {fail("restore framebuffer");result=-1;}else puts("framebuffer_restore=ok");
    free(saved);free(pattern);
done:
    close(fd);if(!result)puts("MIBOX_HDMI_PATTERN_WRITTEN owner_visual_confirmation=required");return result;
}

static int capture(void) {
    /* /dev is the guarded root-owned devtmpfs. No caller-selected paths,
     * framebuffer writes, display ioctls, or raw physical memory access. */
    int directory=open("/dev",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if(directory<0)return fail("capture directory");
    if(fstat(directory,&st) || st.st_uid || (st.st_mode&0022)) {close(directory);errno=EPERM;return fail("capture directory ownership");}
    int fd=open("/dev/graphics/fb0",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0)fd=open("/dev/fb0",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0){close(directory);return fail("capture framebuffer open");}
    struct fb_fix_screeninfo f;struct fb_var_screeninfo v;int result=-1,output=-1,created=0;
    if(fstat(fd,&st) || !S_ISCHR(st.st_mode)) {errno=ENODEV;goto done;}
    if(ioctl(fd,FBIOGET_FSCREENINFO,&f) || ioctl(fd,FBIOGET_VSCREENINFO,&v) || capture_layout(&f,&v))goto done;
    output=openat(directory,".mibox-framebuffer.ppm.tmp",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(output<0)goto done;created=1;
    if(capture_ppm(fd,output,&f,&v) || interrupted || fchmod(output,0644))goto done;
    if(close(output)){output=-1;goto done;}output=-1;
    if(renameat(directory,".mibox-framebuffer.ppm.tmp",directory,"mibox-framebuffer.ppm"))goto done;
    created=0;result=0;
    printf("MIBOX_FRAMEBUFFER_CAPTURE path=/dev/mibox-framebuffer.ppm width=%u height=%u format=P6 scope=framebuffer_only\n",v.xres,v.yres);
done:
    if(result)fail("framebuffer capture");
    if(output>=0)close(output);
    if(created)unlinkat(directory,".mibox-framebuffer.ppm.tmp",0);
    close(fd);close(directory);return result;
}

static void setmask(struct snd_pcm_hw_params *p,int parameter,int value) {struct snd_mask *m=&p->masks[parameter];memset(m,0,sizeof *m);m->bits[value/32]=1u<<(value%32);}
static void interval(struct snd_pcm_hw_params *p,int parameter,unsigned value) {struct snd_interval *i=&p->intervals[parameter-SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];i->min=i->max=value;i->integer=1;}
static int audio(void) {
    int fd=open("/dev/snd/pcmC0D0p",O_RDWR|O_NONBLOCK|O_CLOEXEC);if(fd<0)return fail("PCM open");int result=-1;
    struct snd_pcm_info info={0};if(ioctl(fd,SNDRV_PCM_IOCTL_INFO,&info))goto done;
    printf("pcm_card=%d device=%u id=%.64s name=%.80s\n",info.card,info.device,info.id,info.name);
    struct snd_pcm_hw_params p={0};for(int i=0;i<3;i++)memset(&p.masks[i],255,sizeof p.masks[i]);
    for(int i=0;i<=SNDRV_PCM_HW_PARAM_LAST_INTERVAL-SNDRV_PCM_HW_PARAM_FIRST_INTERVAL;i++)p.intervals[i].max=UINT32_MAX;
    setmask(&p,SNDRV_PCM_HW_PARAM_ACCESS,SNDRV_PCM_ACCESS_RW_INTERLEAVED);setmask(&p,SNDRV_PCM_HW_PARAM_FORMAT,SNDRV_PCM_FORMAT_S16_LE);setmask(&p,SNDRV_PCM_HW_PARAM_SUBFORMAT,SNDRV_PCM_SUBFORMAT_STD);
    interval(&p,SNDRV_PCM_HW_PARAM_CHANNELS,2);interval(&p,SNDRV_PCM_HW_PARAM_RATE,48000);interval(&p,SNDRV_PCM_HW_PARAM_PERIOD_SIZE,1024);interval(&p,SNDRV_PCM_HW_PARAM_PERIODS,4);p.rmask=UINT32_MAX;
    if(ioctl(fd,SNDRV_PCM_IOCTL_HW_PARAMS,&p)) {fail("PCM 48k stereo PCM16 parameters");goto done;}
    struct snd_pcm_sw_params sw={0};sw.tstamp_mode=SNDRV_PCM_TSTAMP_NONE;sw.period_step=1;sw.avail_min=1024;sw.start_threshold=1024;sw.stop_threshold=4096;sw.boundary=1u<<30;
    if(ioctl(fd,SNDRV_PCM_IOCTL_SW_PARAMS,&sw) || ioctl(fd,SNDRV_PCM_IOCTL_PREPARE)) {fail("PCM prepare");goto done;}
    puts("MIBOX_AUDIO_TONE_ACTIVE seconds=3 rate=48000 stereo=left440_right660 amplitude=0.03");fflush(stdout);
    int16_t samples[1024*2];unsigned sent=0;double deadline=now()+8;
    while(sent<144000 && !interrupted && now()<deadline) {
        unsigned count=144000-sent;if(count>1024)count=1024;
        for(unsigned i=0;i<count;i++) {double fade=fmin(1.0,fmin((sent+i)/2400.0,(144000-sent-i)/2400.0));samples[2*i]=(int16_t)(983*fade*sin(2*M_PI*440*(sent+i)/48000));samples[2*i+1]=(int16_t)(983*fade*sin(2*M_PI*660*(sent+i)/48000));}
        struct snd_xferi x={.buf=samples,.frames=count};
        if(ioctl(fd,SNDRV_PCM_IOCTL_WRITEI_FRAMES,&x)) {if(errno==EAGAIN){struct pollfd pollfd={fd,POLLOUT,0};poll(&pollfd,1,100);continue;}fail("PCM write");goto done;}
        if(x.result<0 || (unsigned long)x.result>count){errno=EIO;goto done;}sent+=(unsigned)x.result;
    }
    printf("pcm_frames_accepted=%u\n",sent);if(sent==144000 && !interrupted) {usleep(100000);result=0;}
done:
    ioctl(fd,SNDRV_PCM_IOCTL_DROP);ioctl(fd,SNDRV_PCM_IOCTL_HW_FREE);close(fd);
    if(!result)puts("MIBOX_AUDIO_FRAMES_WRITTEN owner_audible_confirmation=required");else fail("audio test");return result;
}
static int selftest(void) {
    uint8_t b[300]={2,1,6},mac[6]={1,2,3,4,5,6};uint32_t xid=0x12345678;memcpy(b+4,&xid,4);memcpy(b+28,mac,6);memcpy(b+236,"\x63\x82\x53\x63",4);b[240]=53;b[241]=1;b[242]=2;b[243]=255;struct lease l;
    if(parse(b,244,xid,mac,&l) || l.kind!=2 || !parse(b,243,xid,mac,&l) || !parse(b,244,xid+1,mac,&l))return 1;
    b[243]=53;b[244]=1;b[245]=2;b[246]=255;if(!parse(b,247,xid,mac,&l))return 1;
    b[243]=1;b[244]=4;if(!parse(b,247,xid,mac,&l))return 1;
    puts("MIBOX_HARDWARE_PARSER_TEST_OK valid,truncated,wrong_xid,duplicate,truncated_option");return 0;
}
int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IOLBF,0);
    if(argc==2 && !strcmp(argv[1],"selftest"))return selftest();
    if(argc!=2 || (strcmp(argv[1],"network") && strcmp(argv[1],"display") && strcmp(argv[1],"audio") && strcmp(argv[1],"capture")))return 2;
    if(guard())return 1;
    struct sigaction a={0};a.sa_handler=stop;sigaction(SIGTERM,&a,NULL);sigaction(SIGINT,&a,NULL);sigaction(SIGALRM,&a,NULL);alarm(45);
    int r=!strcmp(argv[1],"network")?network("/etc/mibox-network-static"):!strcmp(argv[1],"display")?display():!strcmp(argv[1],"capture")?capture():audio();
    return r || interrupted ? 1 : 0;
}
