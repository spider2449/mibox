/* Host sanitizer test: DHCP options are untrusted network input. */
#define main hardware_main
#include "mibox-hardware.c"
#undef main
int main(void) {
    if(selftest())return 1;
    uint8_t b[1024],mac[6]={1,2,3,4,5,6};uint32_t random=0x79812, xid=0x12345678;
    for(unsigned i=0;i<100000;i++) {
        for(unsigned k=0;k<sizeof b;k++){random=random*1664525+1013904223;b[k]=(uint8_t)(random>>24);}
        b[0]=2;b[1]=1;b[2]=6;memcpy(b+4,&xid,4);memcpy(b+28,mac,6);memcpy(b+236,"\x63\x82\x53\x63",4);
        struct lease lease;parse(b,i%sizeof b,xid,mac,&lease);
    }
    puts("DHCP_SANITIZER_FUZZ_OK cases=100000");return 0;
}
