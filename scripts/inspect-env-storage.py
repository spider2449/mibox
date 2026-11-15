"""Pin exact stock eMMC environment read/write layout before installation."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT=Path(__file__).resolve().parents[1]


def main():
    source=ROOT/'phone-tools/runtime/2026-11-14/bootloader-ucl/bootloader-expanded.bin'
    data=source.read_bytes()
    expected='99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2'
    if hashlib.sha256(data).hexdigest()!=expected:
        raise ValueError('loader hash mismatch')
    addresses=json.loads((ROOT/'artifacts/restoration/2026-11-14/loader-command-addresses.json').read_text())
    if addresses['source_sha256']!=expected: raise ValueError('address report mismatch')
    base=addresses['derived_link_base']
    def word(at): return struct.unpack_from('<I',data,at)[0]
    checks={0x1c6e4:0xe3a00902,0x1c6f4:0xe3072ffc,0x1c76c:0xe3072ffc,
            0x1c778:0xe5850000,0x1c798:0xe3a00902,0x1c7ac:0xe1c901d8,
            0x1c7b4:0xe597c104,0x1c84c:0xe3a00902,0x1c874:0xe3072ffc,
            0x1c8f0:0xe3a00902,0x1c900:0xe1c901d8,0x1c914:0xe597c100,
            0x1c958:0xe3072ffc,0x1c960:0xe1500007,0x1c974:0xeb0000b7}
    for at,value in checks.items():
        if word(at)!=value: raise ValueError(f'instruction changed at {at:#x}')
    write_name=(0x1c688+8+word(0x1c818)+word(0x1c81c)) & 0xffffffff
    read_name=(0x1c85c+8+word(0x1c98c)+word(0x1c994)) & 0xffffffff
    if write_name!=read_name or data[write_name:write_name+4]!=b'env\0':
        raise ValueError('partition name derivation mismatch')
    reference=ROOT/'phone-tools/source-reference/common__env_mmc.c'
    raw=reference.read_bytes()
    variants=[raw,raw.replace(b'\r\n',b'\n')]
    git_hashes=[hashlib.sha1(b'blob '+str(len(v)).encode()+b'\0'+v).hexdigest() for v in variants]
    if '6f06cca2858de8c19d4c1804b42ba1f7399ac495' not in git_hashes:
        raise ValueError('pinned reference Git blob mismatch')
    output=ROOT/'artifacts/restoration/2026-11-15'
    report=dict(loader_sha256=expected,derived_link_base=base,
        environment_bytes=32768,data_bytes=32764,crc_bytes=4,partition_name='env',
        layout='one CRC32 word followed by 32764 data bytes; no redundant flag in inspected path',
        partition_offset_field_bytes=24,write_callback_field=0x104,read_callback_field=0x100,
        write_function_link_address=hex(base+0x1c678),read_function_link_address=hex(base+0x1c848),
        crc_failure_behavior='sets default environment and calls save backend; not a tested fallback',
        write_location='start of named env partition; extent 32768 bytes',
        reference=dict(path='common/env_mmc.c',git_blob_sha1='6f06cca2858de8c19d4c1804b42ba1f7399ac495',
            url='https://github.com/codesnake/uboot-amlogic/blob/c0b0b8cc9bd5901ced2e929ea87b99fae52d528c/common/env_mmc.c'),
        checked_instructions={hex(k):hex(v) for k,v in checks.items()},device_access=False,
        power_loss_atomicity='NOT ESTABLISHED: single-copy update')
    (output/'env-storage-layout.json').write_text(json.dumps(report,indent=2)+'\n')
    result=subprocess.run(['arm-linux-gnueabihf-objdump','-D','-b','binary','-m','arm',
        f'--adjust-vma={base:#x}',f'--start-address={base+0x1c678:#x}',
        f'--stop-address={base+0x1c9ac:#x}',str(source)],capture_output=True,text=True,check=True)
    (output/'loader-env-emmc-disassembly.txt').write_text(result.stdout)
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()
