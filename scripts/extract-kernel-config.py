"""Extract the embedded IKCONFIG gzip from an already expanded stock kernel."""
import argparse
import gzip
import hashlib
import io
import json
import re
from pathlib import Path

SELECTED = ['CONFIG_IKCONFIG', 'CONFIG_IKCONFIG_PROC', 'CONFIG_KEXEC',
            'CONFIG_KEXEC_CORE', 'CONFIG_NAMESPACES', 'CONFIG_PID_NS',
            'CONFIG_UTS_NS', 'CONFIG_IPC_NS', 'CONFIG_NET_NS', 'CONFIG_USER_NS',
            'CONFIG_MODULES', 'CONFIG_MODVERSIONS', 'CONFIG_MODULE_SIG',
            'CONFIG_MODULE_SIG_FORCE', 'CONFIG_BLK_DEV_INITRD', 'CONFIG_RD_GZIP',
            'CONFIG_DEVTMPFS', 'CONFIG_DEVTMPFS_MOUNT', 'CONFIG_TMPFS',
            'CONFIG_USB_G_ANDROID', 'CONFIG_USB_ANDROID', 'CONFIG_USB_FUNCTIONFS',
            'CONFIG_USB_G_SERIAL', 'CONFIG_SECURITY_SELINUX', 'CONFIG_WATCHDOG']


def inspect(kernel, output):
    data = kernel.read_bytes()
    marker = b'IKCFG_ST'
    start = data.find(marker)
    if start < 0 or data.find(marker, start + 1) >= 0:
        raise ValueError('missing or ambiguous IKCONFIG start')
    start += len(marker)
    end = data.find(b'IKCFG_ED', start)
    if end < 0 or data[start:start + 3] != b'\x1f\x8b\x08':
        raise ValueError('missing end marker or gzip header')
    with gzip.GzipFile(fileobj=io.BytesIO(data[start:end])) as stream:
        raw = stream.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError('config exceeds inspection limit')
    text = raw.decode('utf-8')
    config = {}
    for line in text.splitlines():
        match = re.fullmatch(r'(CONFIG_[A-Z0-9_]+)=(.*)', line)
        unset = re.fullmatch(r'# (CONFIG_[A-Z0-9_]+) is not set', line)
        if match:
            config[match[1]] = match[2]
        elif unset:
            config[unset[1]] = 'n'
    if len(config) < 1000:
        raise ValueError('insufficient configuration entries')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'stock-kernel.config').write_bytes(raw)
    report = dict(kernel_sha256=hashlib.sha256(data).hexdigest(),
                  gzip_start=start, gzip_end=end,
                  config_bytes=len(raw), config_sha256=hashlib.sha256(raw).hexdigest(),
                  entries=len(config),
                  selected={name: config.get(name, 'UNKNOWN') for name in SELECTED})
    (output / 'kernel-config.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    inspect(args.kernel, args.output)
