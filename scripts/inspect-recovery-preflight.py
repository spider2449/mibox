"""Validate current saved-env readback and report only recovery-related keys."""
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]


def main():
    evidence = ROOT / 'artifacts/recovery-preflight/2026-11-14'
    data = (ROOT / 'phone-tools/backup/recovery-preflight-20261114/env-prefix.img').read_bytes()
    log = (evidence / 'env-read.txt').read_text(encoding='utf-8-sig')
    hashes = re.findall(r'(?m)^([0-9a-f]{64})\s+/data/local/tmp/mibox-recovery-env-\d+\.img', log)
    if len(hashes) != 1 or len(data) != 32768 or hashlib.sha256(data).hexdigest() != hashes[0]:
        raise ValueError('current environment device/host length/hash mismatch')
    if struct.unpack_from('<I', data)[0] != zlib.crc32(data[4:]):
        raise ValueError('current environment CRC mismatch')
    if b'\0\0' not in data[4:]:
        raise ValueError('missing environment terminator')
    variables = {}
    for entry in data[4:].split(b'\0\0', 1)[0].split(b'\0'):
        if b'=' in entry:
            key, value = entry.split(b'=', 1)
            name = key.decode('ascii')
            if name in variables:
                raise ValueError('duplicate environment variable')
            variables[name] = value.decode('ascii')
    selected = {key: {'present': key in variables, 'value': variables.get(key)}
                for key in ('wipe_data', 'recovery_command', 'boot-recovery', 'upgrade_step',
                            'reboot_mode', 'bootcmd', 'storeboot', 'update')}
    report = {'env_prefix_bytes': len(data), 'sha256': hashes[0], 'device_hash_matches': True,
              'crc32_matches': True, 'variables': selected,
              'scope': 'Current 32768-byte env prefix only, not a full current env-partition backup',
              'device_writes': 'Scratch executable and readback/results only; no raw partition or env write',
              'recovery_booted': False,
              'limit': 'Absence of selected saved-env keys does not prove all automatic recovery command sources inactive.'}
    (evidence / 'env-check.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
