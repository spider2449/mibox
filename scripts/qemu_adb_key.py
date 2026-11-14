"""Generate a QEMU-only RSA key; export only its Android ADB public-key form."""
import base64
import hashlib
import os
import struct
import subprocess
from pathlib import Path


def element(data, offset, tag):
    if offset + 2 > len(data) or data[offset] != tag:
        raise ValueError('unexpected DER tag')
    length = data[offset + 1]
    cursor = offset + 2
    if length & 128:
        count = length & 127
        if not 1 <= count <= 4 or cursor + count > len(data):
            raise ValueError('invalid DER length')
        length = int.from_bytes(data[cursor:cursor + count], 'big')
        cursor += count
    if cursor + length > len(data):
        raise ValueError('truncated DER')
    return data[cursor:cursor + length], cursor + length


def ensure_key(root):
    key = root / 'target/qemu-adb-test-key.pem'
    key.parent.mkdir(parents=True, exist_ok=True)
    if not key.exists():
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt',
                        'rsa_keygen_bits:2048', '-pkeyopt', 'rsa_keygen_pubexp:65537',
                        '-out', str(key)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.chmod(key, 0o600)
    der = subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'],
                         check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    spki, end = element(der, 0, 0x30)
    if end != len(der):
        raise ValueError('trailing public key DER')
    algorithm, cursor = element(spki, 0, 0x30)
    if algorithm != bytes.fromhex('06092a864886f70d0101010500'):
        raise ValueError('expected RSA algorithm')
    bits, end = element(spki, cursor, 3)
    if end != len(spki) or bits[0] != 0:
        raise ValueError('invalid public key bit string')
    sequence, end = element(bits, 1, 0x30)
    if end != len(bits):
        raise ValueError('trailing RSA key DER')
    modulus, cursor = element(sequence, 0, 2)
    exponent, end = element(sequence, cursor, 2)
    n, e = int.from_bytes(modulus, 'big'), int.from_bytes(exponent, 'big')
    if end != len(sequence) or n.bit_length() != 2048 or e != 65537:
        raise ValueError('unexpected RSA parameters')
    binary = (struct.pack('<II', 64, (-pow(n, -1, 1 << 32)) & 0xffffffff) +
              n.to_bytes(256, 'little') + ((1 << 4096) % n).to_bytes(256, 'little') +
              struct.pack('<I', e))
    public = base64.b64encode(binary) + b' mibox-qemu-only\n'
    (root / 'target/qemu-adb-test-key.pub').write_bytes(public)
    return key, public


if __name__ == '__main__':
    _, public = ensure_key(Path(__file__).resolve().parents[1])
    print('QEMU_ADB_PUBLIC_KEY_SHA256=' + hashlib.sha256(public).hexdigest())
