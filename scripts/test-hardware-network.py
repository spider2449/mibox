"""Root-only fixture inside two disposable Linux network namespaces; no device."""
import hashlib
import argparse
import json
import os
import select
import socket
import struct
import subprocess
import sys
import time
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--evidence',type=Path,default=ROOT/'artifacts/network-hdmi-audio/hardware-candidate')
args=parser.parse_args()
if os.geteuid() != 0 or os.readlink('/proc/self/ns/net') == os.readlink('/proc/1/ns/net'):
    raise SystemExit('Run with WSL root under unshare --net; host network must remain untouched')
BINARY = ROOT / 'target/hardware-helper/network-fixture'
subprocess.run(['gcc', '-O1', '-Wall', '-Wextra', '-Werror', '-Wno-misleading-indentation',
                '-o', str(BINARY), str(ROOT / 'src/hardware/test-network.c'), '-lm'], check=True)

def ip(*args):
    return subprocess.run(['ip', *args], check=True, capture_output=True, text=True).stdout

client_code = '''
import json,os,subprocess,sys,time
print('FIXTURE_READY',flush=True)
if sys.stdin.readline().strip() != 'START': raise SystemExit(2)
os.environ['MIBOX_ISOLATED_NET_FIXTURE']='1'
r=subprocess.run([sys.argv[1]],capture_output=True,text=True,timeout=45)
state=dict(exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr,
           addresses=json.loads(subprocess.check_output(['ip','-j','addr','show','eth0'],text=True)),
           routes=json.loads(subprocess.check_output(['ip','-j','route'],text=True)))
print(json.dumps(state),flush=True)
raise SystemExit(r.returncode)
'''

def checksum(data):
    if len(data)%2: data += b'\0'
    n=sum(struct.unpack('!%dH' % (len(data)//2),data))
    while n>>16: n=(n&65535)+(n>>16)
    return (~n)&65535

def run_case(name, nak=False, conflict=False, bad_server=False, fixed=False, invalid_profile=False):
    profile=None
    environment=os.environ.copy()
    if fixed:
        profile=tempfile.NamedTemporaryFile(prefix='mibox-static-fixture-',mode='w',delete=False)
        profile.write('MIBOX_STATIC_IPV4_V1 10.23.0.2 255.255.255.0 10.23.0.1'+(' extra' if invalid_profile else '')+'\n')
        profile.close()
        environment['MIBOX_NETWORK_TEST_PROFILE']=profile.name
    client=subprocess.Popen(['unshare','--net','--',sys.executable,'-c',client_code,str(BINARY)],
                            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=environment)
    capture=[]
    sock=None
    try:
        ready=select.select([client.stdout],[],[],5)[0]
        if not ready or client.stdout.readline().strip()!='FIXTURE_READY':
            raise RuntimeError('isolated client failed to start')
        ip('link','add','fixture0','type','veth','peer','name','eth0')
        ip('link','set','eth0','netns',str(client.pid))
        ip('addr','add','10.23.0.1/24','dev','fixture0')
        if conflict:ip('addr','add','10.23.0.2/24','dev','fixture0')
        ip('link','set','fixture0','up')
        sock=socket.socket(socket.AF_PACKET,socket.SOCK_DGRAM,socket.htons(0x0800))
        sock.bind(('fixture0',0))
        client.stdin.write('START\n');client.stdin.flush()
        deadline=time.monotonic()+40
        while time.monotonic()<deadline and client.poll() is None:
            if not select.select([sock],[],[],0.1)[0]: continue
            try:
                data=sock.recv(2048)
            except OSError as error:
                # The veth disappears when the client namespace exits.
                if error.errno==100:break
                raise
            if len(data)<268 or data[9]!=17: continue
            header=(data[0]&15)*4
            if struct.unpack_from('!HH',data,header)!=(68,67): continue
            udp_length=struct.unpack_from('!H',data,header+4)[0]
            pseudo=data[12:20]+bytes([0,17])+struct.pack('!H',udp_length)
            if checksum(pseudo+data[header:header+udp_length])!=0:
                raise RuntimeError('fixture received invalid DHCP request UDP checksum')
            bootp=data[header+8:]
            if bootp[0]!=1 or bootp[236:240]!=bytes.fromhex('63825363'): continue
            options=bootp[240:]; kind=None; index=0
            while index<len(options):
                tag=options[index];index+=1
                if tag==255:break
                if tag==0:continue
                size=options[index];index+=1
                if tag==53:kind=options[index]
                index+=size
            if kind not in (1,3):continue
            response_type=2 if kind==1 else 6 if nak else 5
            response=bytearray(240);response[0:3]=bytes([2,1,6]);response[4:8]=bootp[4:8]
            response[16:20]=socket.inet_aton('10.23.0.2');response[28:34]=bootp[28:34]
            response[236:240]=bytes.fromhex('63825363')
            server='10.23.0.99' if bad_server and kind==3 else '10.23.0.1'
            response+=bytes([53,1,response_type,54,4])+socket.inet_aton(server)
            response+=bytes([1,4])+socket.inet_aton('255.255.255.0')
            response+=bytes([3,4])+socket.inet_aton('10.23.0.1')
            response+=bytes([51,4])+struct.pack('!I',600)+bytes([255])
            udp=struct.pack('!HHHH',67,68,len(response)+8,0)+response
            packet=bytearray(struct.pack('!BBHHHBBH4s4s',0x45,0,len(udp)+20,0,0,64,17,0,
                                        socket.inet_aton('10.23.0.1'),b'\xff'*4))
            struct.pack_into('!H',packet,10,checksum(packet));packet+=udp
            capture.append(dict(request_type=kind,response_type=response_type,xid=bootp[4:8].hex()))
            sock.sendto(packet,('fixture0',0x0800,0,1,b'\xff'*6))
        client.wait(timeout=3)
        output=client.stdout.read();error=client.stderr.read()
        result=json.loads(output.strip())
        clean=all('UP' not in a['flags'] and not any(i['family']=='inet' for i in a['addr_info']) for a in result['addresses']) and not result['routes']
        failure='static IPv4 profile' if invalid_profile else 'DHCP ACK' if nak else 'IPv4 conflict probe' if conflict else 'DHCP lease contract' if bad_server else None
        expected=(result['exit_code']!=0 and failure in result['stderr']) if failure else (result['exit_code']==0 and 'gateway_echo_replies=3/3' in result['stdout'])
        result.update(case=name,isolated_network_namespaces=True,dhcp_exchange=capture,cleanup_verified=clean,
                      fixture_stderr=error,passed=expected and clean)
        if fixed:result['passed']=result['passed'] and not capture and (bool(failure) or 'static_address=10.23.0.2' in result['stdout'])
        print('NETWORK_FIXTURE '+name+' passed='+str(result['passed']),flush=True)
        return result
    finally:
        if sock:sock.close()
        if client.poll() is None:client.kill()
        client.wait(timeout=5)
        # Only the fixed veth created in this disposable namespace is removed.
        subprocess.run(['ip','link','del','fixture0'],capture_output=True)
        if profile:Path(profile.name).unlink()

results=[run_case('dhcp-gateway-cleanup'),run_case('dhcp-nak-cleanup',nak=True),
         run_case('address-conflict-cleanup',conflict=True),run_case('changed-server-cleanup',bad_server=True),
         run_case('static-gateway-cleanup',fixed=True),run_case('static-conflict-cleanup',fixed=True,conflict=True),
         run_case('static-malformed-profile',fixed=True,invalid_profile=True)]
report=dict(scope='Host Linux namespaces and synthetic DHCP server; no physical Mi Box evidence',
            source_sha256=hashlib.sha256((ROOT/'src/hardware/mibox-hardware.c').read_bytes()).hexdigest(),
            results=results,passed=all(r['passed'] for r in results))
args.evidence.mkdir(parents=True,exist_ok=True)
destination=args.evidence/'network-fixtures.json'
destination.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
if not report['passed']:raise SystemExit(1)
